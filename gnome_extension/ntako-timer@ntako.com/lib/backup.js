// JSON backup / restore and CSV export, in the same formats as the app
// (backup_service.dart) and the admin panel (backend/admin/export.php):
// a file made by any of them can be imported by the others.

export const FORMAT = 'ntako-timer-backup';
export const FORMAT_VERSION = 1;

export class BackupFormatError extends Error {}

export function exportJson(data) {
    return JSON.stringify({
        format: FORMAT,
        version: FORMAT_VERSION,
        exported_at: Date.now(),
        categories: data.categories.map(c => ({
            id: c.id, name: c.name, color: c.color, created_at: c.created_at,
            updated_at: c.updated_at, deleted_at: c.deleted_at,
        })),
        tasks: data.tasks.map(t => ({
            id: t.id, category_id: t.category_id, title: t.title, description: t.description,
            is_completed: t.is_completed, created_at: t.created_at,
            updated_at: t.updated_at, deleted_at: t.deleted_at,
        })),
        sessions: data.sessions.map(s => ({
            id: s.id, task_id: s.task_id, type: s.type, started_at: s.started_at,
            ended_at: s.ended_at, duration_seconds: s.duration_seconds,
            is_completed: s.is_completed, created_at: s.created_at,
        })),
    }, null, 2);
}

const two = n => String(n).padStart(2, '0');

/** Finished sessions, oldest first; ";"-separated with a UTF-8 BOM for Excel. */
export function exportCsv(data) {
    const tasks = new Map(data.tasks.map(t => [t.id, t]));
    const categories = new Map(data.categories.map(c => [c.id, c]));
    const row = fields => `${fields.map(f => {
        const s = String(f);
        return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    }).join(';')}\r\n`;

    let csv = `﻿${row(['Data', 'Inizio', 'Fine', 'Durata', 'Minuti', 'Task', 'Categoria'])}`;
    const sessions = data.sessions.filter(s => s.ended_at !== null)
        .sort((a, b) => a.started_at - b.started_at);
    for (const s of sessions) {
        const start = new Date(s.started_at);
        const end = new Date(s.ended_at);
        const d = s.duration_seconds;
        const task = tasks.get(s.task_id);
        csv += row([
            `${two(start.getDate())}/${two(start.getMonth() + 1)}/${start.getFullYear()}`,
            `${two(start.getHours())}:${two(start.getMinutes())}`,
            `${two(end.getHours())}:${two(end.getMinutes())}`,
            `${Math.floor(d / 3600)}:${two(Math.floor(d % 3600 / 60))}:${two(d % 60)}`,
            Math.round(d / 60),
            task?.title ?? '',
            categories.get(task?.category_id)?.name ?? '',
        ]);
    }
    return csv;
}

// ── Import ───────────────────────────────────────────────────────────────────

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Typed access to one backup row; throws on the first invalid field. The
 *  limits mirror the server's, so an imported row can't block sync. */
class Row {
    constructor(row, where) {
        this.row = row;
        this.where = where;
    }

    fail(key) {
        throw new BackupFormatError(`Backup non valido: campo "${this.where}.${key}" mancante o errato.`);
    }

    check(key, ok) {
        const v = this.row[key];
        return ok(v) ? v : this.fail(key);
    }

    uuid(k) { return this.check(k, v => typeof v === 'string' && UUID.test(v)); }
    optionalUuid(k) { return this.row[k] == null ? null : this.uuid(k); }
    string(k, max, allowEmpty = false) {
        return this.check(k, v => typeof v === 'string' && (allowEmpty || v.length > 0) && [...v].length <= max);
    }

    optionalString(k) { return this.row[k] == null ? null : this.check(k, v => typeof v === 'string'); }
    color(k) { return this.check(k, v => typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v)); }
    bool(k) { return this.check(k, v => typeof v === 'boolean'); }
    timestamp(k) { return this.check(k, v => Number.isInteger(v) && v >= 0); }
    optionalTimestamp(k) { return this.row[k] == null ? null : this.timestamp(k); }
    duration(k) { return this.check(k, v => Number.isInteger(v) && v >= 0 && v <= 2_147_483_647); }
}

function parse(source) {
    let root;
    try {
        root = JSON.parse(source);
    } catch {
        throw new BackupFormatError('Il file non è un JSON valido.');
    }
    if (!root || typeof root !== 'object' || root.format !== FORMAT)
        throw new BackupFormatError('Il file non è un backup di NTAKO Timer.');
    if (!Number.isInteger(root.version) || root.version > FORMAT_VERSION)
        throw new BackupFormatError("Backup creato da una versione più recente: aggiorna l'estensione.");

    const list = (key, build) => {
        const value = root[key] ?? [];
        if (!Array.isArray(value))
            throw new BackupFormatError(`Backup non valido: campo "${key}" errato.`);
        return value.map((r, i) => {
            if (!r || typeof r !== 'object' || Array.isArray(r))
                throw new BackupFormatError(`Backup non valido: campo "${key}[${i}]" errato.`);
            return build(new Row(r, `${key}[${i}]`));
        });
    };

    return {
        categories: list('categories', r => ({
            id: r.uuid('id'), server_id: null, name: r.string('name', 100), color: r.color('color'),
            created_at: r.timestamp('created_at'), updated_at: r.timestamp('updated_at'),
            deleted_at: r.optionalTimestamp('deleted_at'), is_synced: false,
        })),
        tasks: list('tasks', r => ({
            id: r.uuid('id'), server_id: null, category_id: r.optionalUuid('category_id'),
            // The server accepts empty titles, so a server export may have them.
            title: r.string('title', 255, true), description: r.optionalString('description'),
            is_completed: r.bool('is_completed'), created_at: r.timestamp('created_at'),
            updated_at: r.timestamp('updated_at'), deleted_at: r.optionalTimestamp('deleted_at'),
            is_synced: false,
        })),
        sessions: list('sessions', r => ({
            id: r.uuid('id'), server_id: null, task_id: r.optionalUuid('task_id'),
            type: r.string('type', 20), started_at: r.timestamp('started_at'),
            ended_at: r.optionalTimestamp('ended_at'), duration_seconds: r.duration('duration_seconds'),
            is_completed: r.bool('is_completed'), created_at: r.timestamp('created_at'),
            is_synced: false,
        })),
    };
}

const counts = () => ({added: 0, updated: 0, unchanged: 0});

/**
 * Merges a JSON backup into `data` (all or nothing: validation happens
 * first). Nothing local is deleted; categories/tasks keep the most recent
 * updated_at; sessions never lose an end time and keep the longest
 * duration; the session being timed is left alone. Changed rows are marked
 * unsynced so the next sync uploads them.
 */
export function importJson(data, source) {
    const backup = parse(source);
    const result = {categories: counts(), tasks: counts(), sessions: counts()};
    const activeId = data.meta.timer?.sessionId ?? null;

    const lww = (list, incoming, c) => {
        for (const row of incoming) {
            const i = list.findIndex(x => x.id === row.id);
            if (i < 0) {
                list.push(row);
                c.added++;
            } else if (row.updated_at > list[i].updated_at) {
                list[i] = {...row, server_id: list[i].server_id};
                c.updated++;
            } else {
                c.unchanged++;
            }
        }
    };

    lww(data.categories, backup.categories, result.categories);
    // References to rows missing from both file and store are dropped
    // instead of pointing nowhere.
    const catIds = new Set(data.categories.map(c => c.id));
    lww(data.tasks, backup.tasks.map(t =>
        t.category_id && !catIds.has(t.category_id) ? {...t, category_id: null} : t), result.tasks);
    const taskIds = new Set(data.tasks.map(t => t.id));

    for (const s of backup.sessions) {
        const row = s.task_id && !taskIds.has(s.task_id) ? {...s, task_id: null} : s;
        const local = data.sessions.find(x => x.id === row.id);
        if (!local) {
            data.sessions.push(row);
            result.sessions.added++;
            continue;
        }
        if (local.id === activeId) {
            result.sessions.unchanged++;
            continue;
        }
        const endedAt = local.ended_at ?? row.ended_at;
        const duration = Math.max(local.duration_seconds, row.duration_seconds);
        const completed = local.is_completed || row.is_completed;
        if (endedAt === local.ended_at && duration === local.duration_seconds &&
            completed === local.is_completed) {
            result.sessions.unchanged++;
            continue;
        }
        Object.assign(local, {ended_at: endedAt, duration_seconds: duration,
            is_completed: completed, is_synced: false});
        result.sessions.updated++;
    }
    return result;
}

export const changedAnything = r =>
    Object.values(r).some(c => c.added > 0 || c.updated > 0);

/** "ntako_backup_20261022_0130.json" style names. */
export function exportFileName(kind) {
    const d = new Date();
    const stamp = `${d.getFullYear()}${two(d.getMonth() + 1)}${two(d.getDate())}_${two(d.getHours())}${two(d.getMinutes())}`;
    return kind === 'csv' ? `ntako_sessioni_${stamp}.csv` : `ntako_backup_${stamp}.json`;
}
