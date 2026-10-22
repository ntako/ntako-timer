// Preferences window: tasks and categories, history (filters, charts, list),
// account and server, timer settings, import/export. Runs in its own
// process and shares the data file with the panel indicator.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';
import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {
    Store, liveCategories, liveTasks, addCategory, editCategory, deleteCategory,
    addTask, editTask, deleteTask, deleteCompletedTasks, taskLabel, twinTask,
} from './lib/store.js';
import {SyncEngine} from './lib/sync.js';
import {ApiClient, normalizeBaseUrl} from './lib/api.js';
import {createApi, isLoggedIn, login, logout} from './lib/account.js';
import {buildReport, defaultFilters, PERIODS, GROUPS, NO_CATEGORY} from './lib/report.js';
import {exportJson, exportCsv, importJson, changedAnything, exportFileName,
    BackupFormatError} from './lib/backup.js';
import {CATEGORY_COLORS, colorToRgb, formatDay, formatHours, formatTime, validColor} from './lib/format.js';

Gio._promisify(Gtk.FileDialog.prototype, 'save', 'save_finish');
Gio._promisify(Gtk.FileDialog.prototype, 'open', 'open_finish');
Gio._promisify(Adw.AlertDialog.prototype, 'choose', 'choose_finish');

// ── Small helpers ────────────────────────────────────────────────────────────

/** Round dot in a category color. */
function colorDot(hex, size = 12) {
    const area = new Gtk.DrawingArea({content_width: size, content_height: size,
        valign: Gtk.Align.CENTER});
    area.set_draw_func((_a, cr, w, h) => {
        cr.setSourceRGB(...colorToRgb(hex));
        cr.arc(w / 2, h / 2, Math.min(w, h) / 2, 0, 2 * Math.PI);
        cr.fill();
        cr.$dispose();
    });
    return area;
}

function iconButton(icon, tooltip, onClick, cssClass = 'flat') {
    const b = new Gtk.Button({icon_name: icon, tooltip_text: tooltip, valign: Gtk.Align.CENTER,
        css_classes: [cssClass]});
    b.connect('clicked', onClick);
    return b;
}

function toast(window, title) {
    window.add_toast(new Adw.Toast({title, timeout: 4}));
}

/** Removes every group a page currently holds. */
function clearPage(page, groups) {
    for (const g of groups.splice(0))
        page.remove(g);
}

const escape = s => GLib.markup_escape_text(String(s), -1);

/** Asks to confirm a destructive action. */
async function confirm(window, heading, body, action) {
    const dialog = new Adw.AlertDialog({heading, body});
    dialog.add_response('cancel', 'Annulla');
    dialog.add_response('ok', action);
    dialog.set_response_appearance('ok', Adw.ResponseAppearance.DESTRUCTIVE);
    dialog.set_close_response('cancel');
    return await dialog.choose(window, null) === 'ok';
}

// ── Tasks page ───────────────────────────────────────────────────────────────

class TasksPage {
    constructor(window, store) {
        this.window = window;
        this.store = store;
        this.page = new Adw.PreferencesPage({name: 'tasks', title: 'Task', icon_name: 'checkbox-checked-symbolic'});
        this.groups = [];
    }

    refresh() {
        clearPage(this.page, this.groups);
        const data = this.store.data;
        const totals = new Map();
        for (const s of data.sessions.filter(x => x.ended_at !== null))
            totals.set(s.task_id, (totals.get(s.task_id) ?? 0) + s.duration_seconds);

        // Categories
        const cats = new Adw.PreferencesGroup({title: 'Categorie'});
        cats.set_header_suffix(iconButton('list-add-symbolic', 'Nuova categoria',
            () => this._editCategory(null)));
        const live = liveCategories(data);
        if (!live.length)
            cats.add(new Adw.ActionRow({title: 'Nessuna categoria', subtitle: 'Aggiungine una con +'}));
        for (const c of live) {
            const row = new Adw.ActionRow({title: escape(c.name)});
            row.add_prefix(colorDot(c.color));
            row.add_suffix(iconButton('document-edit-symbolic', 'Modifica', () => this._editCategory(c)));
            row.add_suffix(iconButton('user-trash-symbolic', 'Elimina', async () => {
                if (await confirm(this.window, `Eliminare "${c.name}"?`,
                    'I task della categoria restano, senza categoria.', 'Elimina'))
                    this.store.update(d => deleteCategory(d, c.id));
            }));
            cats.add(row);
        }
        this._add(cats);

        // Tasks, grouped by category
        const tasksGroup = new Adw.PreferencesGroup({title: 'Task'});
        const header = new Gtk.Box({spacing: 6});
        const clean = new Gtk.Button({label: 'Elimina completati', css_classes: ['flat'],
            valign: Gtk.Align.CENTER});
        clean.connect('clicked', async () => {
            if (await confirm(this.window, 'Eliminare i task completati?',
                'Le sessioni registrate restano nello storico.', 'Elimina'))
                this.store.update(deleteCompletedTasks);
        });
        header.append(clean);
        header.append(iconButton('list-add-symbolic', 'Nuovo task', () => this._editTask(null)));
        tasksGroup.set_header_suffix(header);

        const tasks = liveTasks(data);
        if (!tasks.length)
            tasksGroup.add(new Adw.ActionRow({title: 'Nessun task', subtitle: 'Aggiungine uno con +'}));
        const sections = [...live.map(c => [c, tasks.filter(t => t.category_id === c.id)]),
            [null, tasks.filter(t => !t.category_id || !live.some(c => c.id === t.category_id))]];
        for (const [cat, list] of sections) {
            if (!list.length)
                continue;
            const exp = new Adw.ExpanderRow({
                title: escape(cat?.name ?? 'Senza categoria'),
                subtitle: `${list.length} task · ${formatHours(list.reduce((s, t) => s + (totals.get(t.id) ?? 0), 0))}`,
                expanded: true,
            });
            exp.add_prefix(colorDot(cat?.color ?? '#9ca3af'));
            for (const t of list.sort((a, b) => Number(a.is_completed) - Number(b.is_completed)))
                exp.add_row(this._taskRow(t, totals.get(t.id) ?? 0));
            tasksGroup.add(exp);
        }
        this._add(tasksGroup);
    }

    _add(group) {
        this.page.add(group);
        this.groups.push(group);
    }

    _taskRow(t, seconds) {
        const firstLine = (t.description ?? '').split('\n')[0];
        const row = new Adw.ActionRow({
            title: escape(t.title || '(senza titolo)'),
            subtitle: escape([seconds ? formatHours(seconds) : null, firstLine || null]
                .filter(Boolean).join(' · ')),
            subtitle_lines: 1,
        });
        if (t.is_completed)
            row.add_css_class('dim-label');
        const check = new Gtk.CheckButton({active: t.is_completed, valign: Gtk.Align.CENTER,
            tooltip_text: 'Completato'});
        check.connect('toggled', () =>
            this.store.update(d => editTask(d, t.id, {is_completed: check.active})));
        row.add_prefix(check);
        row.add_suffix(iconButton('document-edit-symbolic', 'Modifica', () => this._editTask(t)));
        row.add_suffix(iconButton('user-trash-symbolic', 'Elimina', async () => {
            if (await confirm(this.window, `Eliminare "${t.title}"?`,
                'Le sessioni registrate restano nello storico.', 'Elimina'))
                this.store.update(d => deleteTask(d, t.id));
        }));
        return row;
    }

    async _editCategory(cat) {
        const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 12});
        const list = new Gtk.ListBox({css_classes: ['boxed-list']});
        const name = new Adw.EntryRow({title: 'Nome', text: cat?.name ?? ''});
        list.append(name);
        box.append(list);

        let color = cat?.color ?? CATEGORY_COLORS[0];
        const colors = new Gtk.Box({spacing: 6, halign: Gtk.Align.CENTER});
        let group = null;
        for (const hex of CATEGORY_COLORS) {
            const b = new Gtk.ToggleButton({child: colorDot(hex, 20), active: hex === color,
                css_classes: ['flat', 'circular'], tooltip_text: hex});
            if (group)
                b.set_group(group);
            group ??= b;
            b.connect('toggled', () => {
                if (b.active)
                    color = hex;
            });
            colors.append(b);
        }
        box.append(colors);

        const dialog = new Adw.AlertDialog({heading: cat ? 'Modifica categoria' : 'Nuova categoria',
            extra_child: box});
        dialog.add_response('cancel', 'Annulla');
        dialog.add_response('save', 'Salva');
        dialog.set_response_appearance('save', Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response('save');
        if (await dialog.choose(this.window, null) !== 'save')
            return;
        const value = name.text.trim();
        if (!value) {
            toast(this.window, 'Il nome non può essere vuoto');
            return;
        }
        if (value.length > 100) {
            toast(this.window, 'Nome troppo lungo (max 100 caratteri)');
            return;
        }
        this.store.update(d => cat
            ? editCategory(d, cat.id, {name: value, color})
            : addCategory(d, {name: value, color}));
    }

    async _editTask(task) {
        const data = this.store.data;
        const cats = liveCategories(data);
        const list = new Gtk.ListBox({css_classes: ['boxed-list'], selection_mode: Gtk.SelectionMode.NONE});
        const title = new Adw.EntryRow({title: 'Titolo', text: task?.title ?? ''});
        const category = new Adw.ComboRow({title: 'Categoria',
            model: Gtk.StringList.new(['Nessuna', ...cats.map(c => c.name)])});
        category.selected = task?.category_id
            ? Math.max(0, cats.findIndex(c => c.id === task.category_id) + 1) : 0;
        list.append(title);
        list.append(category);

        const desc = new Gtk.TextView({wrap_mode: Gtk.WrapMode.WORD_CHAR, top_margin: 8,
            bottom_margin: 8, left_margin: 8, right_margin: 8});
        desc.buffer.text = task?.description ?? '';
        const scroll = new Gtk.ScrolledWindow({child: desc, min_content_height: 120,
            max_content_height: 260, propagate_natural_height: true, css_classes: ['card']});
        const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 12});
        box.append(list);
        box.append(new Gtk.Label({label: 'Descrizione', xalign: 0, css_classes: ['heading']}));
        box.append(scroll);

        const dialog = new Adw.AlertDialog({heading: task ? 'Modifica task' : 'Nuovo task',
            extra_child: box});
        dialog.add_response('cancel', 'Annulla');
        dialog.add_response('save', 'Salva');
        dialog.set_response_appearance('save', Adw.ResponseAppearance.SUGGESTED);
        if (await dialog.choose(this.window, null) !== 'save')
            return;
        const value = title.text.trim();
        if (!value || value.length > 255) {
            toast(this.window, value ? 'Titolo troppo lungo (max 255 caratteri)' : 'Il titolo non può essere vuoto');
            return;
        }
        const fields = {
            title: value,
            categoryId: category.selected > 0 ? cats[category.selected - 1].id : null,
            description: desc.buffer.text.trim() || null,
        };
        // Two tasks with the same name in one category can't be told apart.
        if (twinTask(this.store.data, {title: value, categoryId: fields.categoryId, exceptId: task?.id}) &&
            !await confirm(this.window, 'Task già esistente',
                `In questa categoria c'è già un task «${value}».`,
                task ? 'Salva comunque' : 'Crea comunque'))
            return;
        this.store.update(d => task
            ? editTask(d, task.id, {title: fields.title, category_id: fields.categoryId,
                description: fields.description})
            : addTask(d, fields));
    }
}

// ── History page ─────────────────────────────────────────────────────────────

/** Stacked columns: hours per bucket, one segment per category. */
class TimeChart {
    constructor() {
        this.report = null;
        this.area = new Gtk.DrawingArea({content_height: 240, hexpand: true, has_tooltip: true});
        this.area.set_draw_func((area, cr, w, h) => {
            this._draw(area, cr, w, h);
            cr.$dispose();
        });
        this.area.connect('query-tooltip', (_a, x, _y, _kb, tooltip) => this._tooltip(x, tooltip));
    }

    set(report) {
        this.report = report;
        this.area.queue_draw();
    }

    _geometry(w, h) {
        const left = 40, bottom = 24, top = 8;
        const n = this.report.labels.length;
        const totals = this.report.labels.map((_, i) =>
            this.report.categories.reduce((s, c) => s + c.buckets[i], 0));
        const maxH = Math.max(1, Math.ceil(Math.max(...totals, 0) / 3600 * 1.1));
        return {left, bottom, top, n, totals, maxH, plotW: w - left - 4, plotH: h - top - bottom};
    }

    _draw(area, cr, w, h) {
        if (!this.report)
            return;
        const g = this._geometry(w, h);
        const fg = area.get_color();
        const ink = a => cr.setSourceRGBA(fg.red, fg.green, fg.blue, a);
        const layout = PangoCairo.create_layout(cr);
        layout.set_font_description(Pango.FontDescription.from_string('Sans 8'));
        const text = (s, x, y, align = 'left') => {
            layout.set_text(s, -1);
            const [, logical] = layout.get_pixel_extents();
            const dx = align === 'center' ? logical.width / 2 : align === 'right' ? logical.width : 0;
            // Kept inside the drawing area: the last label must not be clipped.
            cr.moveTo(Math.min(Math.max(0, x - dx), w - logical.width), y - logical.height / 2);
            PangoCairo.show_layout(cr, layout);
        };

        // Recessive hairline grid with hour labels.
        const step = [1, 2, 5, 10, 20, 50, 100].find(s => g.maxH / s <= 5) ?? 200;
        for (let v = 0; v <= g.maxH; v += step) {
            const y = g.top + g.plotH - v / g.maxH * g.plotH;
            ink(0.12);
            cr.setLineWidth(1);
            cr.moveTo(g.left, Math.round(y) + 0.5);
            cr.lineTo(g.left + g.plotW, Math.round(y) + 0.5);
            cr.stroke();
            ink(0.6);
            text(`${v} h`, g.left - 6, y, 'right');
        }

        const slot = g.plotW / g.n;
        const barW = Math.max(2, Math.min(24, slot * 0.6));
        const labelEvery = Math.max(1, Math.ceil(g.n / (g.plotW / 48)));
        for (let i = 0; i < g.n; i++) {
            const cx = g.left + slot * i + slot / 2;
            let y = g.top + g.plotH;
            const segments = this.report.categories.filter(c => c.buckets[i] > 0);
            segments.forEach((c, k) => {
                const hPx = c.buckets[i] / 3600 / g.maxH * g.plotH;
                const isTop = k === segments.length - 1;
                // 2px of surface between stacked segments.
                const gap = k > 0 ? Math.min(2, hPx / 2) : 0;
                cr.setSourceRGB(...colorToRgb(c.color));
                roundedTop(cr, cx - barW / 2, y - hPx, barW, hPx - gap, isTop ? Math.min(4, hPx / 2) : 0);
                cr.fill();
                y -= hPx;
            });
            if (i % labelEvery === 0) {
                ink(0.6);
                text(this.report.labels[i], cx, g.top + g.plotH + 12, 'center');
            }
        }
    }

    _tooltip(x, tooltip) {
        if (!this.report)
            return false;
        const g = this._geometry(this.area.get_width(), this.area.get_height());
        const i = Math.floor((x - g.left) / (g.plotW / g.n));
        if (i < 0 || i >= g.n || g.totals[i] === 0)
            return false;
        const rows = this.report.categories.filter(c => c.buckets[i] > 0)
            .sort((a, b) => b.buckets[i] - a.buckets[i])
            .map(c => `${formatHours(c.buckets[i])}  ${escape(c.name)}`);
        tooltip.set_markup(`<b>${escape(this.report.labels[i])} · ${formatHours(g.totals[i])}</b>` +
            (rows.length > 1 ? `\n${rows.join('\n')}` : ''));
        return true;
    }
}

function roundedTop(cr, x, y, w, h, r) {
    if (h <= 0)
        return;
    cr.moveTo(x, y + h);
    cr.lineTo(x, y + r);
    if (r > 0)
        cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
    cr.lineTo(x + w - r, y);
    if (r > 0)
        cr.arc(x + w - r, y + r, r, 1.5 * Math.PI, 2 * Math.PI);
    cr.lineTo(x + w, y + h);
    cr.closePath();
}

/** Horizontal bars: name, bar, value at the tip. */
function barList(items) {
    const grid = new Gtk.Grid({column_spacing: 10, row_spacing: 8, margin_top: 10,
        margin_bottom: 10, margin_start: 12, margin_end: 12});
    const max = Math.max(1, ...items.map(i => i.seconds));
    items.forEach((item, row) => {
        const name = new Gtk.Label({label: item.name, xalign: 0, ellipsize: Pango.EllipsizeMode.END,
            width_chars: 18, max_width_chars: 22, tooltip_text: item.subtitle
                ? `${item.name} · ${item.subtitle}` : item.name});
        const bar = new Gtk.DrawingArea({content_height: 14, hexpand: true, valign: Gtk.Align.CENTER});
        bar.set_draw_func((_a, cr, w, h) => {
            const bw = Math.max(2, item.seconds / max * w);
            cr.setSourceRGB(...colorToRgb(item.color));
            // Square at the baseline, 4px rounded data-end.
            const r = Math.min(4, h / 2, bw / 2);
            cr.moveTo(0, 0);
            cr.lineTo(bw - r, 0);
            cr.arc(bw - r, r, r, 1.5 * Math.PI, 2 * Math.PI);
            cr.lineTo(bw, h - r);
            cr.arc(bw - r, h - r, r, 0, 0.5 * Math.PI);
            cr.lineTo(0, h);
            cr.closePath();
            cr.fill();
            cr.$dispose();
        });
        const value = new Gtk.Label({label: formatHours(item.seconds), xalign: 0,
            width_chars: 8, css_classes: ['numeric']});
        grid.attach(name, 0, row, 1, 1);
        grid.attach(bar, 1, row, 1, 1);
        grid.attach(value, 2, row, 1, 1);
    });
    return grid;
}

class HistoryPage {
    constructor(window, store) {
        this.window = window;
        this.store = store;
        this.filters = defaultFilters();
        this.showCharts = true;
        this.page = new Adw.PreferencesPage({name: 'history', title: 'Storico', icon_name: 'document-open-recent-symbolic'});
        this.groups = [];
    }

    refresh() {
        clearPage(this.page, this.groups);
        const data = this.store.data;
        const report = buildReport(data, this.filters, new Date());
        this._add(this._filtersGroup(data, report));
        this._add(this._totalsGroup(report));

        if (!report.sessions.length) {
            const empty = new Adw.PreferencesGroup();
            empty.add(new Adw.ActionRow({title: 'Nessuna sessione con questi filtri.'}));
            this._add(empty);
            return;
        }
        if (this.showCharts) {
            const word = {week: 'settimana', month: 'mese'}[report.group] ?? 'giorno';
            const timeGroup = new Adw.PreferencesGroup({title: `Ore per ${word}, per categoria`});
            const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 8,
                css_classes: ['card'], margin_top: 4});
            if (report.categories.length > 1)
                box.append(this._legend(report));
            const chart = new TimeChart();
            chart.set(report);
            const holder = new Gtk.Box({margin_top: 8, margin_bottom: 8, margin_start: 8, margin_end: 8});
            holder.append(chart.area);
            box.append(holder);
            timeGroup.add(box);
            this._add(timeGroup);

            const byCat = new Adw.PreferencesGroup({title: 'Per categoria'});
            byCat.add(this._card(barList([...report.categories].sort((a, b) => b.seconds - a.seconds))));
            this._add(byCat);
            const byTask = new Adw.PreferencesGroup({title: 'Task principali'});
            byTask.add(this._card(barList(report.tasks.map(t => ({...t, subtitle: t.category})))));
            this._add(byTask);
        } else {
            this._sessionList(data, report);
        }
    }

    _add(group) {
        this.page.add(group);
        this.groups.push(group);
    }

    _card(child) {
        const box = new Gtk.Box({css_classes: ['card']});
        box.append(child);
        return box;
    }

    _legend(report) {
        const flow = new Gtk.FlowBox({selection_mode: Gtk.SelectionMode.NONE, column_spacing: 12,
            max_children_per_line: 6, margin_top: 10, margin_start: 12, margin_end: 12});
        for (const c of report.categories) {
            const item = new Gtk.Box({spacing: 6});
            item.append(colorDot(c.color, 10));
            item.append(new Gtk.Label({label: c.name, css_classes: ['caption']}));
            flow.append(item);
        }
        return flow;
    }

    _filtersGroup(data, report) {
        const g = new Adw.PreferencesGroup({title: 'Filtri'});
        const toggle = new Gtk.Box({css_classes: ['linked'], valign: Gtk.Align.CENTER});
        const charts = new Gtk.ToggleButton({label: 'Grafici', active: this.showCharts});
        const list = new Gtk.ToggleButton({label: 'Lista', active: !this.showCharts, group: charts});
        charts.connect('toggled', () => {
            if (charts.active !== this.showCharts) {
                this.showCharts = charts.active;
                this._later();
            }
        });
        toggle.append(charts);
        toggle.append(list);
        g.set_header_suffix(toggle);

        const combo = (title, options, current, onPick) => {
            const row = new Adw.ComboRow({title, model: Gtk.StringList.new(options.map(o => o[1]))});
            row.selected = Math.max(0, options.findIndex(o => o[0] === current));
            row.connect('notify::selected', () => onPick(options[row.selected][0]));
            g.add(row);
            return row;
        };

        combo('Periodo', PERIODS, this.filters.period, v => {
            this.filters.period = v;
            if (v === 'custom' && !this.filters.customFrom) {
                const now = new Date();
                this.filters.customFrom = new Date(now.getFullYear(), now.getMonth(), 1);
                this.filters.customTo = now;
            }
            this._later();
        });
        if (this.filters.period === 'custom') {
            const row = new Adw.ActionRow({title: 'Intervallo'});
            row.add_suffix(this._dateButton('customFrom'));
            row.add_suffix(new Gtk.Label({label: '–'}));
            row.add_suffix(this._dateButton('customTo'));
            g.add(row);
        }

        const cats = [[null, 'Tutte le categorie'], [NO_CATEGORY, 'Senza categoria'],
            ...[...data.categories].sort((a, b) => a.name.localeCompare(b.name))
                .map(c => [c.id, c.deleted_at ? `${c.name} (eliminata)` : c.name])];
        combo('Categoria', cats, this.filters.categoryId, v => {
            this.filters.categoryId = v;
            this.filters.taskId = null; // a task from another category would match nothing
            this._later();
        });

        const tasks = data.tasks.filter(t => {
            if (this.filters.categoryId === NO_CATEGORY)
                return !t.category_id;
            return !this.filters.categoryId || t.category_id === this.filters.categoryId;
        }).sort((a, b) => Number(!!a.deleted_at) - Number(!!b.deleted_at) || a.title.localeCompare(b.title));
        combo('Task', [[null, 'Tutti i task'], ...tasks.map(t =>
            [t.id, `${taskLabel(data, t)}${t.deleted_at ? ' (eliminato)' : ''}`])],
        this.filters.taskId, v => {
            this.filters.taskId = v;
            this._later();
        });
        combo('Raggruppa per', GROUPS, this.filters.group, v => {
            this.filters.group = v;
            this._later();
        });

        const last = new Date(report.end.getFullYear(), report.end.getMonth(), report.end.getDate() - 1);
        g.set_description(last.getTime() === report.start.getTime()
            ? formatDay(report.start)
            : `${formatDay(report.start)} – ${formatDay(last)}`);
        return g;
    }

    _dateButton(key) {
        const value = this.filters[key];
        const calendar = new Gtk.Calendar();
        calendar.select_day(GLib.DateTime.new_local(value.getFullYear(), value.getMonth() + 1,
            value.getDate(), 0, 0, 0));
        const button = new Gtk.MenuButton({label: formatDay(value), valign: Gtk.Align.CENTER,
            popover: new Gtk.Popover({child: calendar})});
        calendar.connect('day-selected', () => {
            const d = calendar.get_date();
            this.filters[key] = new Date(d.get_year(), d.get_month() - 1, d.get_day_of_month());
            button.popover.popdown();
            this._later();
        });
        return button;
    }

    _totalsGroup(report) {
        const g = new Adw.PreferencesGroup();
        const box = new Gtk.Box({homogeneous: true, spacing: 12, css_classes: ['card']});
        const stat = (value, label) => {
            const col = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, margin_top: 12,
                margin_bottom: 12, margin_start: 12});
            col.append(new Gtk.Label({label: value, xalign: 0, css_classes: ['title-2']}));
            col.append(new Gtk.Label({label, xalign: 0, css_classes: ['dim-label', 'caption']}));
            box.append(col);
        };
        stat(formatHours(report.totalSeconds), 'Tempo');
        stat(String(report.sessions.length), 'Sessioni');
        stat(String(report.activeDays), 'Giorni attivi');
        stat(report.activeDays ? formatHours(Math.floor(report.totalSeconds / report.activeDays)) : '—',
            'Media per giorno');
        g.add(box);
        return g;
    }

    _sessionList(data, report) {
        const tasks = new Map(data.tasks.map(t => [t.id, t]));
        const byDay = new Map();
        for (const s of report.sessions) {
            const d = new Date(s.started_at);
            const key = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
            if (!byDay.has(key))
                byDay.set(key, []);
            byDay.get(key).push(s);
        }
        const weekday = ['domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato'];
        for (const [key, sessions] of byDay) {
            const d = new Date(key);
            const g = new Adw.PreferencesGroup({
                title: `${weekday[d.getDay()]} ${formatDay(d)}`,
                description: formatHours(sessions.reduce((a, s) => a + s.duration_seconds, 0)),
            });
            for (const s of sessions) {
                const row = new Adw.ActionRow({
                    title: escape(taskLabel(data, tasks.get(s.task_id))),
                    subtitle: `${formatTime(new Date(s.started_at))} – ${formatTime(new Date(s.ended_at))}`,
                });
                row.add_suffix(new Gtk.Label({label: formatHours(s.duration_seconds),
                    css_classes: ['numeric']}));
                g.add(row);
            }
            this._add(g);
        }
    }

    /** Rebuild after the current signal handler returns (it may own a widget being removed). */
    _later() {
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this.refresh();
            return GLib.SOURCE_REMOVE;
        });
    }
}

// ── Account page ─────────────────────────────────────────────────────────────

class AccountPage {
    constructor(window, store, settings, sync) {
        this.window = window;
        this.store = store;
        this.settings = settings;
        this.sync = sync;
        this.page = new Adw.PreferencesPage({name: 'account', title: 'Account', icon_name: 'avatar-default-symbolic'});
        this.groups = [];
    }

    refresh() {
        clearPage(this.page, this.groups);
        this._add(this._serverGroup());
        this._add(isLoggedIn(this.settings) ? this._accountGroup() : this._loginGroup());
    }

    _add(group) {
        this.page.add(group);
        this.groups.push(group);
    }

    _serverGroup() {
        const g = new Adw.PreferencesGroup({title: 'Server',
            description: 'Indirizzo dell\'API NTAKO. Cambiandolo verrai disconnesso.'});
        const entry = new Adw.EntryRow({title: 'Indirizzo del backend',
            text: this.settings.get_string('server-url'), show_apply_button: true});
        const status = new Adw.ActionRow({subtitle: '', visible: false});
        entry.connect('apply', async () => {
            const url = normalizeBaseUrl(entry.text);
            status.visible = true;
            if (!url) {
                status.subtitle = 'Inserisci un indirizzo http:// o https://';
                return;
            }
            status.subtitle = 'Verifica in corso…';
            const problem = await ApiClient.checkServer(url);
            if (problem) {
                status.subtitle = escape(problem);
                return;
            }
            await this._switchServer(url);
        });
        g.add(entry);
        g.add(status);
        return g;
    }

    async _switchServer(url) {
        if (url === this.settings.get_string('server-url'))
            return;
        // Token and sync position belong to the previous server.
        if (isLoggedIn(this.settings))
            await logout(this.settings);
        this.sync.resetCursor();
        this.settings.set_string('server-url', url);
        toast(this.window, 'Server salvato');
        this.refresh();
    }

    _loginGroup() {
        const hasServer = this.settings.get_string('server-url') !== '';
        const g = new Adw.PreferencesGroup({title: 'Accedi',
            description: hasServer ? 'Senza account i dati restano solo su questo computer.'
                : 'Per accedere imposta prima l\'indirizzo del server qui sopra. ' +
                  'Senza account i dati restano solo su questo computer.'});
        const email = new Adw.EntryRow({title: 'Email', input_purpose: Gtk.InputPurpose.EMAIL});
        const password = new Adw.PasswordEntryRow({title: 'Password'});
        g.add(email);
        g.add(password);
        const error = new Adw.ActionRow({visible: false, css_classes: ['error']});
        g.add(error);

        const buttons = new Gtk.Box({spacing: 8, halign: Gtk.Align.END, margin_top: 12});
        const run = async register => {
            buttons.sensitive = false;
            error.visible = false;
            try {
                await login(this.settings, this.store, {email: email.text.trim(),
                    password: password.text, register});
                toast(this.window, register ? 'Account creato' : 'Accesso effettuato');
                this.refresh();
                this._syncNow();
            } catch (e) {
                error.title = escape(e.message);
                error.visible = true;
            } finally {
                buttons.sensitive = true;
            }
        };
        const reg = new Gtk.Button({label: 'Crea account'});
        reg.connect('clicked', () => run(true));
        const log = new Gtk.Button({label: 'Accedi', css_classes: ['suggested-action']});
        log.connect('clicked', () => run(false));
        password.connect('entry-activated', () => run(false));
        buttons.append(reg);
        buttons.append(log);
        buttons.sensitive = hasServer;
        g.add(buttons);
        return g;
    }

    _accountGroup() {
        const g = new Adw.PreferencesGroup({title: 'Account'});
        const who = new Adw.ActionRow({title: escape(this.settings.get_string('account-email')),
            subtitle: 'Account attivo'});
        who.add_prefix(new Gtk.Image({icon_name: 'avatar-default-symbolic'}));
        g.add(who);

        const m = this.store.data.meta;
        const syncRow = new Adw.ActionRow({
            title: 'Sincronizza ora',
            subtitle: escape(m.lastSyncError ? `Ultimo tentativo non riuscito: ${m.lastSyncError}`
                : m.lastSyncAt ? `Ultima sincronizzazione: ${formatDay(new Date(m.lastSyncAt))} ${formatTime(new Date(m.lastSyncAt))}`
                    : 'Mai sincronizzato'),
            activatable: true,
        });
        syncRow.add_suffix(new Gtk.Image({icon_name: 'emblem-synchronizing-symbolic'}));
        syncRow.connect('activated', () => this._syncNow(true));
        g.add(syncRow);

        const out = new Adw.ActionRow({title: 'Esci', activatable: true, css_classes: ['error']});
        out.add_suffix(new Gtk.Image({icon_name: 'system-log-out-symbolic'}));
        out.connect('activated', async () => {
            await logout(this.settings);
            this.refresh();
        });
        g.add(out);
        return g;
    }

    async _syncNow(showResult = false) {
        try {
            await this.sync.sync();
            if (showResult)
                toast(this.window, 'Sincronizzazione completata');
        } catch (e) {
            toast(this.window, `Sync non riuscita: ${e.message}`);
        }
        this.refresh();
    }
}

// ── Settings page ────────────────────────────────────────────────────────────

class SettingsPage {
    constructor(window, store, settings) {
        this.window = window;
        this.store = store;
        this.page = new Adw.PreferencesPage({name: 'settings', title: 'Impostazioni', icon_name: 'preferences-system-symbolic'});

        const t = new Adw.PreferencesGroup({title: 'Timer'});
        const spin = (key, title, subtitle, max, step) => {
            const row = Adw.SpinRow.new_with_range(0, max, step);
            Object.assign(row, {title, subtitle});
            settings.bind(key, row, 'value', Gio.SettingsBindFlags.DEFAULT);
            t.add(row);
        };
        spin('session-alert-minutes', 'Avviso dopo (minuti)', 'Notifica quando la sessione dura così tanto; 0 = mai', 240, 5);
        spin('break-minutes', 'Durata della pausa (minuti)', 'Promemoria quando la pausa finisce; 0 = nessuno', 60, 1);
        const sw = (key, title) => {
            const row = new Adw.SwitchRow({title});
            settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
            t.add(row);
        };
        sw('alert-sound', 'Suono con gli avvisi');
        sw('show-time-in-panel', 'Mostra il tempo nella barra in alto');
        const interval = Adw.SpinRow.new_with_range(1, 120, 1);
        Object.assign(interval, {title: 'Sincronizza ogni (minuti)'});
        settings.bind('sync-interval-minutes', interval, 'value', Gio.SettingsBindFlags.DEFAULT);
        t.add(interval);
        this.page.add(t);

        const d = new Adw.PreferencesGroup({title: 'Dati',
            description: 'Stessi formati dell\'app e del pannello admin.'});
        const action = (title, subtitle, icon, fn) => {
            const row = new Adw.ActionRow({title, subtitle, activatable: true});
            row.add_suffix(new Gtk.Image({icon_name: icon}));
            row.connect('activated', () => fn().catch(e => {
                if (!e.matches?.(Gtk.DialogError, Gtk.DialogError.DISMISSED))
                    toast(this.window, `Errore: ${e.message}`);
            }));
            d.add(row);
        };
        action('Esporta backup', 'Tutti i dati in un file JSON reimportabile', 'document-save-symbolic',
            () => this._save(exportFileName('json'), exportJson(this.store.data)));
        action('Esporta sessioni (CSV)', 'Per Excel o Fogli Google', 'x-office-spreadsheet-symbolic',
            () => this._save(exportFileName('csv'), exportCsv(this.store.data)));
        action('Importa backup', 'Unisce un backup JSON ai dati attuali, senza cancellare nulla',
            'document-open-symbolic', () => this._import());
        this.page.add(d);
    }

    async _save(name, content) {
        const file = await new Gtk.FileDialog({initial_name: name}).save(this.window, null);
        file.replace_contents(new TextEncoder().encode(content), null, false,
            Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        toast(this.window, 'File esportato');
    }

    async _import() {
        const filter = new Gtk.FileFilter({name: 'Backup JSON'});
        filter.add_pattern('*.json');
        const filters = new Gio.ListStore({item_type: Gtk.FileFilter});
        filters.append(filter);
        const file = await new Gtk.FileDialog({filters}).open(this.window, null);
        const [, bytes] = file.load_contents(null);
        let source;
        try {
            source = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
        } catch {
            toast(this.window, 'Il file non è un testo UTF-8.');
            return;
        }
        try {
            const result = this.store.update(data => importJson(data, source));
            const line = (label, c) => `${label}: ${c.added} nuovi, ${c.updated} aggiornati`;
            toast(this.window, changedAnything(result)
                ? `Importazione completata. ${line('Task', result.tasks)}, ${line('Sessioni', result.sessions)}`
                : 'Nessuna novità: i dati erano già presenti.');
        } catch (e) {
            if (!(e instanceof BackupFormatError))
                throw e;
            toast(this.window, e.message);
        }
    }
}

// ── Window ───────────────────────────────────────────────────────────────────

export default class NtakoTimerPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const store = new Store();
        const sync = new SyncEngine(store, createApi(settings), () => logout(settings));
        window.set_default_size(760, 820);
        window.search_enabled = false;

        const tasks = new TasksPage(window, store);
        const history = new HistoryPage(window, store);
        const account = new AccountPage(window, store, settings, sync);
        const prefs = new SettingsPage(window, store, settings);
        for (const p of [tasks, history, account])
            p.refresh();
        for (const p of [tasks.page, history.page, account.page, prefs.page])
            window.add(p);

        // Changes from the panel (or the other pages) refresh the pages.
        let pending = 0;
        const listener = store.connect(() => {
            if (pending)
                return;
            pending = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                pending = 0;
                tasks.refresh();
                history.refresh();
                account.refresh();
                return GLib.SOURCE_REMOVE;
            });
        });
        const settingsId = settings.connect('changed::account-email', () => account.refresh());
        window.connect('close-request', () => {
            store.disconnect(listener);
            settings.disconnect(settingsId);
            if (pending)
                GLib.source_remove(pending);
            store.destroy();
            return false;
        });
    }
}
