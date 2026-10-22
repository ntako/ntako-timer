// Timer state machine, persisted in the store (data.meta.timer) so it
// survives a shell restart and is the same in the panel and the window.
// Unlike the app, a pause is persisted too: paused time is never counted.

import {newId, nowMs} from './store.js';

/** 'idle' | 'running' | 'paused' */
export function timerStatus(data) {
    const t = data.meta.timer;
    if (!t)
        return 'idle';
    return t.runningSince === null ? 'paused' : 'running';
}

/** Seconds tracked so far in the current session (0 when idle). */
export function elapsedSeconds(data, now = nowMs()) {
    const t = data.meta.timer;
    if (!t)
        return 0;
    const running = t.runningSince === null ? 0 : (now - t.runningSince) / 1000;
    return Math.floor(t.accumulated + running);
}

/** Seconds left in the break after a pause; 0 when none. */
export function breakRemaining(data, now = nowMs()) {
    const until = data.meta.timer?.breakUntil;
    return until ? Math.max(0, Math.ceil((until - now) / 1000)) : 0;
}

export function selectTask(data, taskId) {
    if (!data.meta.timer)
        data.meta.selectedTaskId = taskId;
}

export function start(data, taskId = data.meta.selectedTaskId) {
    if (data.meta.timer)
        return;
    const now = nowMs();
    const id = newId();
    data.sessions.push({
        id, server_id: null, task_id: taskId ?? null, type: 'tracking',
        started_at: now, ended_at: null, duration_seconds: 0,
        is_completed: false, created_at: now, is_synced: false,
    });
    data.meta.selectedTaskId = taskId ?? null;
    data.meta.timer = {sessionId: id, taskId: taskId ?? null, runningSince: now,
        accumulated: 0, breakUntil: null, alertFired: false};
}

/** Pauses; `breakMinutes` > 0 starts a break countdown. */
export function pause(data, breakMinutes = 0) {
    const t = data.meta.timer;
    if (!t || t.runningSince === null)
        return;
    const now = nowMs();
    t.accumulated += (now - t.runningSince) / 1000;
    t.runningSince = null;
    t.breakUntil = breakMinutes > 0 ? now + breakMinutes * 60_000 : null;
}

export function resume(data) {
    const t = data.meta.timer;
    if (!t || t.runningSince !== null)
        return;
    t.runningSince = nowMs();
    t.breakUntil = null;
}

/** Closes the session with the tracked time and clears the timer. */
export function stop(data) {
    const t = data.meta.timer;
    if (!t)
        return;
    const now = nowMs();
    const s = data.sessions.find(x => x.id === t.sessionId);
    if (s) {
        s.ended_at = now;
        s.duration_seconds = elapsedSeconds(data, now);
        s.is_completed = true;
        s.is_synced = false;
    }
    data.meta.timer = null;
}

/** Seconds tracked today on finished sessions plus the running one. */
export function todaySeconds(data, now = nowMs()) {
    const d = new Date(now);
    const start = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    const done = data.sessions
        .filter(s => s.ended_at !== null && s.started_at >= start)
        .reduce((sum, s) => sum + s.duration_seconds, 0);
    return done + elapsedSeconds(data, now);
}

// ── Timers on other devices ──────────────────────────────────────────────────

/** Open sessions other than this device's own: timers running elsewhere,
 *  as last received by sync (a pause over there isn't known here). */
export function runningElsewhere(data) {
    const mine = data.meta.timer?.sessionId ?? null;
    return data.sessions.filter(s => s.ended_at === null && s.id !== mine)
        .sort((a, b) => a.started_at - b.started_at);
}

/** Seconds since a session started. */
export const sinceStart = (s, now = nowMs()) => Math.max(0, Math.floor((now - s.started_at) / 1000));

/** Stops timers running elsewhere: their sessions end now, with the time
 *  since they started; the next push tells those devices to stop. */
export function stopElsewhere(data, ids) {
    const now = nowMs();
    for (const s of data.sessions.filter(x => ids.includes(x.id) && x.ended_at === null)) {
        s.ended_at = now;
        s.duration_seconds = sinceStart(s, now);
        s.is_completed = true;
        s.is_synced = false;
    }
}

/** True when sync brought this device's running session back closed:
 *  another device stopped it. */
export function stoppedElsewhere(data) {
    const t = data.meta.timer;
    const s = t && data.sessions.find(x => x.id === t.sessionId);
    return Boolean(s && s.ended_at !== null);
}

/** Clears the local timer if its session was stopped elsewhere; true if so. */
export function clearIfStoppedElsewhere(data) {
    if (!stoppedElsewhere(data))
        return false;
    data.meta.timer = null;
    return true;
}
