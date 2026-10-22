// Local data store: one JSON file shared by the shell process (panel
// indicator) and the preferences process (window). Same data model as the
// app's local database, with the field names of the backup format.
//
// Every write re-reads the file, applies the change and replaces the file
// atomically, so neither process overwrites what the other just saved.
// Each process watches the file and reloads when the other one writes.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const FORMAT_VERSION = 1;

/** Default location: ~/.local/share/ntako-timer/data.json */
export function defaultStorePath() {
    return GLib.build_filenamev([GLib.get_user_data_dir(), 'ntako-timer', 'data.json']);
}

export function emptyData() {
    return {
        version: FORMAT_VERSION,
        categories: [],
        tasks: [],
        sessions: [],
        meta: {
            syncCursor: 0,
            lastSyncAt: null,
            lastSyncError: null,
            selectedTaskId: null,
            // Running/paused session: {sessionId, taskId, runningSince (ms|null),
            // accumulated (s), breakUntil (ms|null), alertFired}
            timer: null,
        },
    };
}

export const nowMs = () => Date.now();

export const newId = () => GLib.uuid_string_random();

export class Store {
    constructor(path = defaultStorePath()) {
        this._file = Gio.File.new_for_path(path);
        this._listeners = new Set();
        this._monitor = null;
        this._data = this._read();
    }

    /** Current data. Treat as read-only: change it through update(). */
    get data() {
        return this._data;
    }

    /**
     * Applies `fn` to the freshest data on disk and saves it. `fn` mutates
     * the object it receives; its return value is returned.
     */
    update(fn) {
        const data = this._read();
        const result = fn(data);
        this._write(data);
        this._data = data;
        this._emit();
        return result;
    }

    /** Re-reads the file (e.g. after another process wrote it). */
    reload() {
        this._data = this._read();
        this._emit();
    }

    /** Calls `cb()` whenever the data changes, here or in the other process. */
    connect(cb) {
        this._listeners.add(cb);
        if (!this._monitor) {
            const dir = this._file.get_parent();
            if (!dir.query_exists(null))
                dir.make_directory_with_parents(null);
            this._monitor = this._file.monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
            this._monitorId = this._monitor.connect('changed', (_m, _f, _o, event) => {
                if (event === Gio.FileMonitorEvent.CHANGES_DONE_HINT ||
                    event === Gio.FileMonitorEvent.RENAMED ||
                    event === Gio.FileMonitorEvent.MOVED_IN ||
                    event === Gio.FileMonitorEvent.CREATED)
                    this.reload();
            });
        }
        return cb;
    }

    disconnect(cb) {
        this._listeners.delete(cb);
    }

    destroy() {
        this._listeners.clear();
        if (this._monitor) {
            this._monitor.disconnect(this._monitorId);
            this._monitor.cancel();
            this._monitor = null;
        }
    }

    _emit() {
        for (const cb of this._listeners) {
            try {
                cb();
            } catch (e) {
                logError(e, 'ntako-timer store listener');
            }
        }
    }

    _read() {
        try {
            const [, bytes] = this._file.load_contents(null);
            const data = JSON.parse(new TextDecoder().decode(bytes));
            const base = emptyData();
            return {...base, ...data, meta: {...base.meta, ...data.meta}};
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND))
                logError(e, 'ntako-timer: unreadable data file, starting empty');
            return emptyData();
        }
    }

    _write(data) {
        const dir = this._file.get_parent();
        if (!dir.query_exists(null))
            dir.make_directory_with_parents(null);
        const bytes = new TextEncoder().encode(JSON.stringify(data));
        // replace_contents writes a temporary file and renames it over the
        // target: a reader never sees a half-written file.
        this._file.replace_contents(bytes, null, false,
            Gio.FileCreateFlags.REPLACE_DESTINATION, null);
    }
}

// ── Queries ──────────────────────────────────────────────────────────────────

export const liveCategories = data =>
    data.categories.filter(c => c.deleted_at === null)
        .sort((a, b) => a.name.localeCompare(b.name));

export const liveTasks = data =>
    data.tasks.filter(t => t.deleted_at === null)
        .sort((a, b) => b.created_at - a.created_at);

export const byId = list => new Map(list.map(x => [x.id, x]));

/** "Sviluppo (Arundo)": titles can repeat across categories. */
export function taskLabel(data, task) {
    if (!task)
        return 'Senza task';
    const title = task.title || '(senza titolo)';
    const cat = data.categories.find(c => c.id === task.category_id && c.deleted_at === null);
    return cat ? `${title} (${cat.name})` : title;
}

const sameName = (a, b) => a.trim().toLocaleLowerCase() === b.trim().toLocaleLowerCase();

/** Another live task with this title in this category, if any. */
export const twinTask = (data, {title, categoryId = null, exceptId = null}) =>
    data.tasks.find(t => t.deleted_at === null && t.id !== exceptId &&
        t.category_id === categoryId && sameName(t.title, title));

// ── Edits (same rules as the app: every change bumps updated_at and is
//    marked unsynced, deletes are soft) ───────────────────────────────────────

export function addCategory(data, {name, color}) {
    const now = nowMs();
    const c = {id: newId(), server_id: null, name, color, created_at: now,
        updated_at: now, deleted_at: null, is_synced: false};
    data.categories.push(c);
    return c;
}

export function editCategory(data, id, changes) {
    const c = data.categories.find(x => x.id === id);
    if (!c)
        return;
    Object.assign(c, changes, {updated_at: nowMs(), is_synced: false});
}

export function deleteCategory(data, id) {
    editCategory(data, id, {deleted_at: nowMs()});
}

export function addTask(data, {title, categoryId = null, description = null}) {
    const now = nowMs();
    const t = {id: newId(), server_id: null, category_id: categoryId, title,
        description, is_completed: false, created_at: now, updated_at: now,
        deleted_at: null, is_synced: false};
    data.tasks.push(t);
    return t;
}

export function editTask(data, id, changes) {
    const t = data.tasks.find(x => x.id === id);
    if (!t)
        return;
    Object.assign(t, changes, {updated_at: nowMs(), is_synced: false});
}

export function deleteTask(data, id) {
    editTask(data, id, {deleted_at: nowMs()});
}

export function deleteCompletedTasks(data) {
    for (const t of data.tasks.filter(x => x.is_completed && x.deleted_at === null))
        deleteTask(data, t.id);
}
