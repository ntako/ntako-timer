// Top bar indicator: the running time, and a menu to pick the task,
// start / pause / resume / stop, see today's total and sync.
// Everything else (tasks, history, account, settings) is in the
// preferences window, which shares the same data file.

import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {Store, byId, liveCategories, liveTasks, taskLabel} from './lib/store.js';
import * as timer from './lib/timer.js';
import {SyncEngine} from './lib/sync.js';
import {createApi, isLoggedIn, logout} from './lib/account.js';
import {formatClock, formatHours, formatTime} from './lib/format.js';

const ICON = 'alarm-symbolic';
const ICON_ELSEWHERE = 'emblem-shared-symbolic';

/** While a timer is open here or elsewhere, sync this often (seconds). */
const LIVE_SYNC_SECONDS = 30;

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.5, 'NTAKO Timer');
        this._ext = ext;
        this._settings = ext.getSettings();
        this._store = new Store();
        this._sync = new SyncEngine(this._store, createApi(this._settings),
            () => logout(this._settings));

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        this._icon = new St.Icon({icon_name: ICON, style_class: 'system-status-icon'});
        this._label = new St.Label({y_align: Clutter.ActorAlign.CENTER, style_class: 'ntako-timer-label'});
        box.add_child(this._icon);
        box.add_child(this._label);
        this.add_child(box);

        this._buildMenu();

        // Edits from the window (new task, import…) go out soon. Only when
        // there are *more* unsynced rows than before: a failing sync also
        // writes the file, and must not retrigger itself forever.
        this._unsynced = this._countUnsynced();
        this._storeListener = this._store.connect(() => {
            // Sync brought our running session back closed: another device
            // stopped it.
            if (timer.stoppedElsewhere(this._store.data) &&
                this._store.update(d => timer.clearIfStoppedElsewhere(d)))
                this._notify('Timer fermato', 'Il timer è stato fermato da un altro dispositivo.');
            const unsynced = this._countUnsynced();
            if (unsynced > this._unsynced)
                this._requestSync();
            this._unsynced = unsynced;
            this._refresh();
        });
        this._settingsIds = [
            'show-time-in-panel', 'account-email', 'server-url', 'sync-interval-minutes',
        ].map(key => this._settings.connect(`changed::${key}`, () => this._onSettingsChanged(key)));

        this._tickId = 0;
        this._syncTimerId = 0;
        this._pendingSyncId = 0;
        this._scheduleSync();
        this._refresh();
        this.syncNow();
    }

    _countUnsynced() {
        const d = this._store.data;
        return [d.categories, d.tasks, d.sessions]
            .reduce((n, list) => n + list.filter(x => !x.is_synced).length, 0);
    }

    // ── Menu ────────────────────────────────────────────────────────────────

    _buildMenu() {
        this._status = new PopupMenu.PopupMenuItem('', {reactive: false});
        this.menu.addMenuItem(this._status);

        // Timers running on other devices; rebuilt only when that list
        // changes, so "Ferma" stays clickable while the times tick.
        this._remoteSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._remoteSection);
        this._remoteItems = new Map();

        this._taskMenu = new PopupMenu.PopupSubMenuMenuItem('');
        this.menu.addMenuItem(this._taskMenu);

        this._startItem = this._action('Avvia', 'media-playback-start-symbolic',
            d => timer.start(d));
        // When a timer runs elsewhere, starting asks what to do with it.
        this._startReplaceItem = this._action("Ferma l'altro e avvia", 'media-playback-start-symbolic',
            d => {
                timer.stopElsewhere(d, timer.runningElsewhere(d).map(x => x.id));
                timer.start(d);
            });
        this._startBothItem = this._action('Avvia comunque', 'media-playback-start-symbolic',
            d => timer.start(d));
        this._pauseItem = this._action('Pausa', 'media-playback-pause-symbolic',
            d => timer.pause(d, this._settings.get_int('break-minutes')));
        this._resumeItem = this._action('Riprendi', 'media-playback-start-symbolic',
            d => timer.resume(d));
        this._stopItem = this._action('Ferma e salva', 'media-playback-stop-symbolic',
            d => timer.stop(d), () => this._requestSync());

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._todayItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        this.menu.addMenuItem(this._todayItem);

        this._syncItem = new PopupMenu.PopupImageMenuItem('', 'emblem-synchronizing-symbolic');
        this._syncItem.connect('activate', () => this.syncNow(true));
        this.menu.addMenuItem(this._syncItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const open = new PopupMenu.PopupImageMenuItem('Task, storico e impostazioni…',
            'preferences-system-symbolic');
        open.connect('activate', () => this._ext.openPreferences());
        this.menu.addMenuItem(open);

        // Refresh the task list right before the menu opens.
        this.menu.connect('open-state-changed', (_m, open_) => {
            if (open_)
                this._refresh();
        });
    }

    _action(label, icon, change, after = () => {}) {
        const item = new PopupMenu.PopupImageMenuItem(label, icon);
        item.connect('activate', () => {
            this._store.update(change);
            after();
        });
        this.menu.addMenuItem(item);
        return item;
    }

    _fillTaskMenu(data, status) {
        const sub = this._taskMenu.menu;
        sub.removeAll();
        const tasks = byId(data.tasks);
        const selected = status === 'idle' ? data.meta.selectedTaskId : data.meta.timer.taskId;
        const task = tasks.get(selected);
        this._taskMenu.label.text = `Task: ${task ? taskLabel(data, task) : 'Nessun task'}`;
        // The task is fixed once the session started.
        this._taskMenu.setSensitive(status === 'idle');
        if (status !== 'idle')
            return;

        const pick = (label, id) => {
            const item = new PopupMenu.PopupMenuItem(label);
            item.setOrnament(id === selected ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
            item.connect('activate', () => this._store.update(d => timer.selectTask(d, id)));
            sub.addMenuItem(item);
        };
        pick('Nessun task', null);
        const open = liveTasks(data).filter(t => !t.is_completed);
        const groups = [...liveCategories(data).map(c => [c.id, c.name]), [null, 'Senza categoria']];
        for (const [catId, catName] of groups) {
            const inGroup = open.filter(t => t.category_id === catId)
                .sort((a, b) => a.title.localeCompare(b.title));
            if (!inGroup.length)
                continue;
            sub.addMenuItem(new PopupMenu.PopupSeparatorMenuItem(catName));
            for (const t of inGroup)
                pick(t.title || '(senza titolo)', t.id);
        }
    }

    _fillRemote(data, remote) {
        const tasks = byId(data.tasks);
        const ids = remote.map(s => s.id).join(',');
        if (ids !== this._remoteIds) {
            this._remoteIds = ids;
            this._remoteSection.removeAll();
            this._remoteItems.clear();
            for (const s of remote) {
                const title = taskLabel(data, tasks.get(s.task_id));
                const info = new PopupMenu.PopupImageMenuItem('', ICON_ELSEWHERE, {reactive: false});
                const stop = new PopupMenu.PopupMenuItem(`    Ferma «${title}»`);
                stop.connect('activate', () => {
                    this._store.update(d => timer.stopElsewhere(d, [s.id]));
                    this._requestSync();
                });
                this._remoteSection.addMenuItem(info);
                this._remoteSection.addMenuItem(stop);
                this._remoteItems.set(s.id, {info, title});
            }
            if (remote.length)
                this._remoteSection.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        }
        for (const s of remote) {
            const item = this._remoteItems.get(s.id);
            if (item)
                item.info.label.text = `Altro dispositivo · ${item.title} · ${formatClock(timer.sinceStart(s))}`;
        }
    }

    // ── State → UI ──────────────────────────────────────────────────────────

    _refresh() {
        const data = this._store.data;
        const status = timer.timerStatus(data);
        const elapsed = timer.elapsedSeconds(data);
        const brk = timer.breakRemaining(data);

        const remote = timer.runningElsewhere(data);
        // Idle here but timing elsewhere: show that one, with its own icon.
        const elsewhere = status === 'idle' && remote.length > 0;

        const showTime = this._settings.get_boolean('show-time-in-panel') &&
            (status !== 'idle' || elsewhere);
        this._label.visible = showTime;
        this._label.text = elsewhere ? formatClock(timer.sinceStart(remote[0]))
            : status === 'paused' && brk > 0
                ? `${formatClock(elapsed)} · pausa ${formatClock(brk)}`
                : formatClock(elapsed);
        this._icon.icon_name = elsewhere ? ICON_ELSEWHERE : {
            running: 'media-record-symbolic',
            paused: 'media-playback-pause-symbolic',
            idle: ICON,
        }[status];

        this._fillRemote(data, remote);
        this._status.label.text = {
            idle: elsewhere ? 'Fermo qui · in corso su un altro dispositivo' : 'Timer fermo',
            running: `In corso · ${formatClock(elapsed)}`,
            paused: brk > 0 ? `In pausa · pausa finisce tra ${formatClock(brk)}` : 'In pausa',
        }[status];
        this._fillTaskMenu(data, status);
        this._startItem.visible = status === 'idle' && !remote.length;
        this._startReplaceItem.visible = status === 'idle' && remote.length > 0;
        this._startBothItem.visible = status === 'idle' && remote.length > 0;
        this._pauseItem.visible = status === 'running';
        this._resumeItem.visible = status === 'paused';
        this._stopItem.visible = status !== 'idle';
        this._todayItem.label.text = `Oggi: ${formatHours(timer.todaySeconds(data))}`;

        const m = data.meta;
        this._syncItem.visible = true;
        if (!isLoggedIn(this._settings))
            this._syncItem.label.text = 'Non collegato: accedi dalle impostazioni';
        else if (this._sync.running)
            this._syncItem.label.text = 'Sincronizzazione…';
        else if (m.lastSyncError)
            this._syncItem.label.text = `Sync non riuscita: ${m.lastSyncError}`;
        else
            this._syncItem.label.text = m.lastSyncAt
                ? `Sincronizza (ultima ${formatTime(new Date(m.lastSyncAt))})`
                : 'Sincronizza ora';

        this._checkAlerts(data, status, elapsed);
        this._updateTicker(status !== 'idle' || remote.length > 0);
    }

    _updateTicker(ticking) {
        if (ticking && !this._tickId) {
            this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            });
        } else if (!ticking && this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
    }

    // ── Alerts ──────────────────────────────────────────────────────────────

    _checkAlerts(data, status, elapsed) {
        const t = data.meta.timer;
        if (!t)
            return;
        const alertMin = this._settings.get_int('session-alert-minutes');
        if (status === 'running' && alertMin > 0 && !t.alertFired && elapsed >= alertMin * 60) {
            this._store.update(d => {
                if (d.meta.timer)
                    d.meta.timer.alertFired = true;
            });
            this._notify('Sessione completata!', `Hai lavorato per ${alertMin} minuti. Prenditi una pausa.`);
        }
        if (status === 'paused' && t.breakUntil && Date.now() >= t.breakUntil) {
            this._store.update(d => {
                if (d.meta.timer)
                    d.meta.timer.breakUntil = null;
            });
            this._notify('Pausa terminata!', 'Riprendi il lavoro.');
        }
    }

    _notify(title, body) {
        if (!this._source) {
            this._source = new MessageTray.Source({title: 'NTAKO Timer', iconName: ICON});
            this._source.connect('destroy', () => {
                this._source = null;
            });
            Main.messageTray.add(this._source);
        }
        const n = new MessageTray.Notification({source: this._source, title, body,
            urgency: MessageTray.Urgency.HIGH});
        this._source.addNotification(n);
        if (this._settings.get_boolean('alert-sound'))
            global.display.get_sound_player().play_from_theme('complete', title, null);
    }

    // ── Sync ────────────────────────────────────────────────────────────────

    /** Syncs now; `fromMenu` shows a notification when it fails. */
    async syncNow(fromMenu = false) {
        if (!isLoggedIn(this._settings))
            return;
        const run = this._sync.sync();
        this._refresh();
        try {
            await run;
        } catch (e) {
            if (fromMenu)
                this._notify('Sincronizzazione non riuscita', e.message);
        }
        if (this._store)
            this._refresh();
    }

    /** Sync a little later, so a burst of edits makes one request. */
    _requestSync() {
        if (this._pendingSyncId)
            GLib.source_remove(this._pendingSyncId);
        this._pendingSyncId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._pendingSyncId = 0;
            this.syncNow();
            return GLib.SOURCE_REMOVE;
        });
    }

    /** Every 30 s while a timer is open here or elsewhere (so starts and
     *  stops on other devices show up quickly), otherwise every N minutes. */
    _scheduleSync() {
        if (this._syncTimerId)
            GLib.source_remove(this._syncTimerId);
        this._syncTimerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, LIVE_SYNC_SECONDS, () => {
            const d = this._store.data;
            const open = d.sessions.some(x => x.ended_at === null);
            const every = this._settings.get_int('sync-interval-minutes') * 60_000;
            if (open || Date.now() - (d.meta.lastSyncAt ?? 0) >= every)
                this.syncNow();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _onSettingsChanged(key) {
        if (key === 'sync-interval-minutes')
            this._scheduleSync();
        if (key === 'account-email' && isLoggedIn(this._settings))
            this.syncNow();
        this._refresh();
    }

    destroy() {
        for (const id of [this._tickId, this._syncTimerId, this._pendingSyncId]) {
            if (id)
                GLib.source_remove(id);
        }
        this._tickId = this._syncTimerId = this._pendingSyncId = 0;
        this._settingsIds.forEach(id => this._settings.disconnect(id));
        this._store.disconnect(this._storeListener);
        this._store.destroy();
        this._store = null;
        this._source?.destroy();
        super.destroy();
    }
});

export default class NtakoTimerExtension extends Extension {
    enable() {
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
