// Tests for the extension's libraries (no GNOME Shell needed).
//
//   gjs -m gnome_extension/tests/run.js [http://localhost:18080/api]
//
// With a backend URL, the sync tests run against it (they register a
// throwaway account); without one they are skipped.

import GLib from 'gi://GLib';
import System from 'system';

import {Store, addCategory, addTask, editTask, emptyData} from '../ntako-timer@ntako.com/lib/store.js';
import * as timer from '../ntako-timer@ntako.com/lib/timer.js';
import {buildReport, periodRange, effectiveGroup, NO_CATEGORY} from '../ntako-timer@ntako.com/lib/report.js';
import {exportJson, exportCsv, importJson, changedAnything, BackupFormatError} from '../ntako-timer@ntako.com/lib/backup.js';
import {ApiClient, ApiError, normalizeBaseUrl} from '../ntako-timer@ntako.com/lib/api.js';
import {SyncEngine} from '../ntako-timer@ntako.com/lib/sync.js';
import {formatHours, formatClock} from '../ntako-timer@ntako.com/lib/format.js';

const BACKEND = ARGV[0] ?? null;
const HERE = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
const ARUNDO = GLib.build_filenamev([HERE, '..', '..', 'SHEETEXAMPLE', 'arundo_import.json']);

let failures = 0;
const results = [];
async function test(name, fn) {
    try {
        await fn();
        results.push(`PASS ${name}`);
    } catch (e) {
        failures++;
        results.push(`FAIL ${name}\n     ${e.message}\n${e.stack?.split('\n').slice(0, 3).join('\n')}`);
    }
}
function eq(actual, expected, what = '') {
    const a = JSON.stringify(actual), b = JSON.stringify(expected);
    if (a !== b)
        throw new Error(`${what} expected ${b}, got ${a}`);
}
function ok(cond, what) {
    if (!cond)
        throw new Error(what);
}
const tmpStore = () => {
    const dir = GLib.dir_make_tmp('ntako-test-XXXXXX');
    return GLib.build_filenamev([dir, 'data.json']);
};
const readText = path => new TextDecoder().decode(GLib.file_get_contents(path)[1]);

// ── format ───────────────────────────────────────────────────────────────────
await test('formatHours / formatClock', () => {
    eq(formatHours(3725), '1h 02m');
    eq(formatHours(300), '5m');
    eq(formatHours(3599), '1h 00m', 'rounded');
    eq(formatClock(3725), '1:02:05');
    eq(formatClock(65), '01:05');
    eq(normalizeBaseUrl(' www.example.com/backend/api/ '), 'https://www.example.com/backend/api');
    eq(normalizeBaseUrl('ftp://x.it'), null);
});

// ── store: two instances on one file, like shell + preferences ──────────────
await test('store is shared between processes', () => {
    const path = tmpStore();
    const a = new Store(path), b = new Store(path);
    a.update(d => addCategory(d, {name: 'Lavoro', color: '#6366f1'}));
    // b writes without reloading first: update() must re-read, not clobber a's change.
    b.update(d => addTask(d, {title: 'Report'}));
    const c = new Store(path);
    eq(c.data.categories.map(x => x.name), ['Lavoro']);
    eq(c.data.tasks.map(x => x.title), ['Report']);
    ok(c.data.tasks[0].is_synced === false, 'new rows are unsynced');
});

// ── timer ────────────────────────────────────────────────────────────────────
await test('timer: pause is not counted, stop closes the session', () => {
    const d = emptyData();
    const t0 = Date.now();
    timer.start(d, 'task-1');
    eq(timer.timerStatus(d), 'running');
    d.meta.timer.runningSince = t0 - 600_000; // started 10 min ago
    timer.pause(d, 5);
    eq(timer.timerStatus(d), 'paused');
    ok(timer.breakRemaining(d) > 290, 'break countdown started');
    const paused = timer.elapsedSeconds(d);
    ok(paused >= 600 && paused < 602, `10 min before pause, got ${paused}`);
    d.meta.timer.accumulated = 600; // pretend the pause lasted 2 hours: nothing changes
    timer.resume(d);
    d.meta.timer.runningSince -= 60_000; // 1 more minute of work
    timer.stop(d);
    eq(timer.timerStatus(d), 'idle');
    const s = d.sessions[0];
    ok(s.duration_seconds >= 660 && s.duration_seconds < 662, `11 min tracked, got ${s.duration_seconds}`);
    ok(s.ended_at !== null && s.is_completed && !s.is_synced, 'closed and unsynced');
    eq(s.task_id, 'task-1');
});

// ── report: same rules as app and admin panel ───────────────────────────────
await test('report periods and grouping', () => {
    const now = new Date(2026, 9, 21, 18, 30); // Wednesday
    const r = p => periodRange({period: p}, now).map(d => d.toDateString());
    eq(r('week'), [new Date(2026, 9, 19).toDateString(), new Date(2026, 9, 26).toDateString()]);
    eq(r('lastMonth'), [new Date(2026, 8, 1).toDateString(), new Date(2026, 9, 1).toDateString()]);
    eq(periodRange({period: 'custom', customFrom: new Date(2026, 9, 1), customTo: new Date(2026, 9, 21)}, now)[1].getDate(), 22);
    eq(effectiveGroup({group: 'auto'}, new Date(2026, 9), new Date(2026, 10)), 'day');
    eq(effectiveGroup({group: 'auto'}, new Date(2026, 6), new Date(2026, 10)), 'week');
    eq(effectiveGroup({group: 'auto'}, new Date(2026, 0), new Date(2027, 0)), 'month');
});

await test('report on the Arundo file matches the file itself', () => {
    const source = readText(ARUNDO);
    const d = emptyData();
    importJson(d, source);
    const rows = JSON.parse(source).sessions;
    const days = new Set(rows.map(s => new Date(s.started_at).toDateString()));
    const r = buildReport(d, {period: 'all', group: 'auto'});
    eq(r.totalSeconds, rows.reduce((a, s) => a + s.duration_seconds, 0), 'total');
    eq(r.sessions.length, rows.length, 'sessions');
    eq(r.activeDays, days.size, 'active days');
    eq(r.group, 'month');
    eq(r.categories[0].buckets.reduce((a, b) => a + b, 0), r.totalSeconds, 'every session in a bucket');
    const none = buildReport(d, {period: 'all', categoryId: NO_CATEGORY});
    eq(none.sessions.length, 0, 'all Arundo sessions have a category');
});

// ── backup ───────────────────────────────────────────────────────────────────
await test('backup: export → import round trip, merge, validation, CSV', () => {
    const d = emptyData();
    const c = addCategory(d, {name: 'Clienti', color: '#22c55e'});
    const t = addTask(d, {title: 'Riunione; "kickoff"', categoryId: c.id});
    timer.start(d, t.id);
    d.meta.timer.runningSince -= 3_725_000;
    timer.stop(d);

    const fresh = emptyData();
    const res = importJson(fresh, exportJson(d));
    eq([res.categories.added, res.tasks.added, res.sessions.added], [1, 1, 1]);
    ok(!changedAnything(importJson(fresh, exportJson(d))), 'second import changes nothing');

    editTask(d, t.id, {title: 'Nuovo titolo'});
    d.tasks.find(x => x.id === t.id).updated_at += 1; // never the same ms as the creation
    eq(importJson(fresh, exportJson(d)).tasks.updated, 1, 'newer task wins');

    for (const [bad, part] of [['nope', 'JSON valido'], ['{"format":"x"}', 'non è un backup'],
        [JSON.stringify({format: 'ntako-timer-backup', version: 1, tasks: [{id: 'x'}]}), 'tasks[0].id']]) {
        try {
            importJson(emptyData(), bad);
            throw new Error(`accepted ${bad}`);
        } catch (e) {
            ok(e instanceof BackupFormatError && e.message.includes(part), e.message);
        }
    }

    const lines = exportCsv(d).split('\r\n');
    eq(lines[0], '﻿Data;Inizio;Fine;Durata;Minuti;Task;Categoria');
    ok(lines[1].endsWith(';1:02:05;62;Nuovo titolo;Clienti'), lines[1]);
});

// ── sync against a real backend ─────────────────────────────────────────────
if (BACKEND) {
    const email = `gnome-${GLib.uuid_string_random().slice(0, 8)}@test.it`;
    const anon = new ApiClient(() => BACKEND, async () => null);
    const {token} = await anon.post('/auth/register', {email, password: 'password123'});

    const device = (path, tok = token) => {
        const store = new Store(path);
        let unauthorized = false;
        const api = new ApiClient(() => BACKEND, async () => tok);
        const sync = new SyncEngine(store, api, () => {
            unauthorized = true;
        });
        return {store, sync, wasUnauthorized: () => unauthorized};
    };

    await test('server check accepts a backend, rejects a wrong path', async () => {
        eq(await ApiClient.checkServer(BACKEND), null);
        ok((await ApiClient.checkServer(BACKEND.replace(/\/api$/, '/nope'))).includes('404'), 'wrong path → 404 message');
    });

    await test('sync: push in chunks beyond server limits, pull on a second device', async () => {
        const a = device(tmpStore());
        a.store.update(d => {
            const c = addCategory(d, {name: 'Lavoro', color: '#6366f1'});
            for (let i = 0; i < 130; i++) // > 100 tasks per push
                addTask(d, {title: `Task ${i}`, categoryId: c.id});
            timer.start(d, d.tasks[0].id);
            d.meta.timer.runningSince -= 90_000;
            timer.stop(d);
        });
        await a.sync.sync();
        ok(a.store.data.tasks.every(t => t.is_synced), 'all 130 tasks pushed');
        ok(a.store.data.sessions[0].is_synced, 'session pushed');
        eq(a.store.data.meta.lastSyncError, null);

        const b = device(tmpStore());
        await b.sync.sync();
        eq([b.store.data.categories.length, b.store.data.tasks.length, b.store.data.sessions.length], [1, 130, 1]);
        eq(b.store.data.sessions[0].duration_seconds, 90);
    });

    await test('sync: an edit made during the push stays unsynced, then goes', async () => {
        const a = device(tmpStore());
        const id = a.store.update(d => addTask(d, {title: 'Prima'}).id);
        const pushing = a.sync.sync();
        // Edit while the request is in flight (written by "the other process").
        new Store(a.store._file.get_path()).update(d => {
            editTask(d, id, {title: 'Durante'});
            d.tasks.find(t => t.id === id).updated_at += 1; // never the same ms as the original
        });
        await pushing;
        a.store.reload();
        const after = a.store.data.tasks.find(t => t.id === id);
        eq(after.title, 'Durante');
        ok(!after.is_synced, 'edited row still pending after the push that missed it');
        await a.sync.sync();
        ok(a.store.data.tasks.find(t => t.id === id).is_synced, 'synced on next round');
    });

    await test('live timers: B sees A running, stops it, A notices', async () => {
        const a = device(tmpStore()), b = device(tmpStore());
        a.store.update(d => {
            const t = addTask(d, {title: 'Remoto'});
            timer.start(d, t.id);
        });
        await a.sync.sync();
        await b.sync.sync();
        const remote = timer.runningElsewhere(b.store.data);
        eq(remote.length, 1, 'B sees one remote timer');
        eq(b.store.data.tasks.find(t => t.id === remote[0].task_id)?.title, 'Remoto');
        eq(timer.runningElsewhere(a.store.data).length, 0, "A's own timer is not 'elsewhere'");

        b.store.update(d => timer.stopElsewhere(d, [remote[0].id]));
        await b.sync.sync();
        eq(timer.runningElsewhere(b.store.data).length, 0, 'gone on B once stopped');

        await a.sync.sync();
        ok(timer.stoppedElsewhere(a.store.data), 'A sees its session closed');
        ok(a.store.update(d => timer.clearIfStoppedElsewhere(d)), 'A clears its timer');
        eq(timer.timerStatus(a.store.data), 'idle');
        ok(!timer.stoppedElsewhere(a.store.data), 'only once');
    });

    await test('live timers: an open session > 4 h survives another device starting', async () => {
        const a = device(tmpStore()), b = device(tmpStore());
        a.store.update(d => {
            timer.start(d, null);
            d.sessions[0].started_at -= 5 * 3600_000; // open for 5 hours
        });
        await a.sync.sync();
        b.store.update(d => timer.start(d, null));
        await b.sync.sync(); // pushes B's open session
        await a.sync.sync();
        ok(!timer.stoppedElsewhere(a.store.data), "A's 5 h timer was not closed by B's start");
        eq(timer.runningElsewhere(a.store.data).length, 1, 'A sees B running');
    });

    await test('sync: bad token → 401, unauthorized callback, readable error', async () => {
        const x = device(tmpStore(), 'a.b.c');
        x.store.update(d => addTask(d, {title: 'x'}));
        try {
            await x.sync.sync();
            throw new Error('sync with a bad token succeeded');
        } catch (e) {
            ok(e instanceof ApiError && e.status === 401, e.message);
        }
        ok(x.wasUnauthorized(), 'callback called');
        eq(x.store.data.meta.lastSyncError, 'Sessione scaduta: accedi di nuovo.');
    });
}

print(results.join('\n'));
print(`\n${results.length - failures}/${results.length} ok${BACKEND ? '' : ' (sync tests skipped: no backend URL)'}`);
System.exit(failures ? 1 : 0);
