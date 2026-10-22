// Sync with the backend: same protocol and merge rules as the app
// (lib/features/sync/sync_service.dart).
//
// - push: unsynced rows, in chunks within the server's limits; a row is
//   marked synced only if it didn't change while the push was in flight
// - pull: paginated by server-assigned version cursor; categories/tasks
//   keep the most recent updated_at, a session with unpushed local changes
//   is kept as is
// - one sync at a time: a call during a sync schedules one more round

import {nowMs} from './store.js';

const PAGE_SIZE = 200;
// Server limits per push (backend/api/sync/push.php).
const CHUNK = {categories: 100, tasks: 100, sessions: 500};

const chunks = (list, size) =>
    Array.from({length: Math.ceil(list.length / size)}, (_, i) => list.slice(i * size, (i + 1) * size));

export class SyncEngine {
    /**
     * @param {Store} store
     * @param {ApiClient} api
     * @param {() => void} onUnauthorized  called on 401: the token is no longer valid
     */
    constructor(store, api, onUnauthorized = () => {}) {
        this._store = store;
        this._api = api;
        this._onUnauthorized = onUnauthorized;
        this._running = null;
        this._again = false;
    }

    get running() {
        return this._running !== null;
    }

    /** Pushes then pulls. Concurrent calls are coalesced into one more round. */
    sync() {
        if (this._running) {
            this._again = true;
            return this._running;
        }
        this._running = this._rounds().finally(() => {
            this._running = null;
        });
        return this._running;
    }

    /** Forget how far we pulled: the next sync downloads everything. */
    resetCursor() {
        this._store.update(d => {
            d.meta.syncCursor = 0;
        });
    }

    async _rounds() {
        try {
            do {
                this._again = false;
                await this._push();
                await this._pull();
            } while (this._again);
            this._store.update(d => {
                d.meta.lastSyncAt = nowMs();
                d.meta.lastSyncError = null;
            });
        } catch (e) {
            if (e.status === 401)
                this._onUnauthorized();
            this._store.update(d => {
                d.meta.lastSyncError = e.status === 401
                    ? 'Sessione scaduta: accedi di nuovo.'
                    : e.message;
            });
            throw e;
        }
    }

    async _push() {
        this._store.reload();
        const data = this._store.data;
        const categories = data.categories.filter(c => !c.is_synced);
        const tasks = data.tasks.filter(t => !t.is_synced);
        const sessions = data.sessions.filter(s => !s.is_synced);

        // Categories before the tasks that reference them, tasks before sessions.
        for (const batch of chunks(categories, CHUNK.categories))
            await this._pushBatch({categories: batch});
        for (const batch of chunks(tasks, CHUNK.tasks))
            await this._pushBatch({tasks: batch});
        for (const batch of chunks(sessions, CHUNK.sessions))
            await this._pushBatch({sessions: batch});
    }

    async _pushBatch({categories = [], tasks = [], sessions = []}) {
        const result = await this._api.post('/sync/push', {
            categories: categories.map(c => ({
                client_id: c.id, name: c.name, color: c.color,
                created_at: c.created_at, updated_at: c.updated_at, deleted_at: c.deleted_at,
            })),
            tasks: tasks.map(t => ({
                client_id: t.id, category_client_id: t.category_id, title: t.title,
                description: t.description, type: 'tracker', is_completed: t.is_completed ? 1 : 0,
                created_at: t.created_at, updated_at: t.updated_at, deleted_at: t.deleted_at,
            })),
            sessions: sessions.map(s => ({
                client_id: s.id, task_client_id: s.task_id, type: s.type,
                started_at: s.started_at, ended_at: s.ended_at, duration_seconds: s.duration_seconds,
                is_completed: s.is_completed ? 1 : 0, created_at: s.created_at,
            })),
        });

        const sent = {
            categories: new Map(categories.map(c => [c.id, c])),
            tasks: new Map(tasks.map(t => [t.id, t])),
            sessions: new Map(sessions.map(s => [s.id, s])),
        };
        this._store.update(d => {
            // Only rows unchanged since they were sent: an edit made while
            // the push was in flight stays pending for the next round.
            const mark = (list, acks, sentMap, unchanged) => {
                for (const {client_id: id, server_id: serverId} of acks ?? []) {
                    const row = list.find(x => x.id === id);
                    if (row && sentMap.has(id) && unchanged(row, sentMap.get(id))) {
                        row.server_id = serverId;
                        row.is_synced = true;
                    }
                }
            };
            mark(d.categories, result.synced_categories, sent.categories,
                (row, s) => row.updated_at === s.updated_at);
            mark(d.tasks, result.synced_tasks, sent.tasks,
                (row, s) => row.updated_at === s.updated_at);
            mark(d.sessions, result.synced_sessions, sent.sessions,
                (row, s) => row.ended_at === s.ended_at);
        });
    }

    async _pull() {
        let cursor = this._store.data.meta.syncCursor ?? 0;
        for (;;) {
            // eslint-disable-next-line no-await-in-loop
            const page = await this._api.get('/sync/pull', {cursor, limit: PAGE_SIZE});
            cursor = page.cursor;
            // Merge the page and advance the cursor in one write.
            this._store.update(d => {
                mergeCategories(d, page.categories);
                mergeTasks(d, page.tasks);
                mergeSessions(d, page.sessions);
                d.meta.syncCursor = cursor;
            });
            if (page.has_more !== true)
                break;
        }
    }
}

function upsert(list, row) {
    const i = list.findIndex(x => x.id === row.id);
    if (i >= 0)
        list[i] = row;
    else
        list.push(row);
}

function mergeCategories(d, rows) {
    for (const m of rows) {
        const local = d.categories.find(c => c.id === m.client_id);
        if (local && local.updated_at > m.updated_at)
            continue;
        upsert(d.categories, {
            id: m.client_id, server_id: m.id, name: m.name, color: m.color ?? '#6366f1',
            created_at: m.created_at, updated_at: m.updated_at, deleted_at: m.deleted_at,
            is_synced: true,
        });
    }
}

function mergeTasks(d, rows) {
    for (const m of rows) {
        const local = d.tasks.find(t => t.id === m.client_id);
        if (local && local.updated_at > m.updated_at)
            continue;
        upsert(d.tasks, {
            id: m.client_id, server_id: m.id, category_id: m.category_client_id ?? null,
            title: m.title, description: m.description ?? null,
            is_completed: m.is_completed === 1, created_at: m.created_at,
            updated_at: m.updated_at, deleted_at: m.deleted_at, is_synced: true,
        });
    }
}

function mergeSessions(d, rows) {
    for (const m of rows) {
        const local = d.sessions.find(s => s.id === m.client_id);
        // A local change not pushed yet (e.g. stopped mid-sync) is newer than
        // the server copy: keep it, the next push sends it and the server merges.
        if (local && !local.is_synced)
            continue;
        upsert(d.sessions, {
            id: m.client_id, server_id: m.id, task_id: m.task_client_id ?? null,
            type: m.type, started_at: m.started_at, ended_at: m.ended_at,
            duration_seconds: m.duration_seconds, is_completed: m.is_completed === 1,
            created_at: m.created_at, is_synced: true,
        });
    }
}
