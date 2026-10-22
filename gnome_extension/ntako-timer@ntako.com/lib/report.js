// Filtered time report for the history page.
//
// Same periods and grouping rules as the app (history_report.dart) and the
// admin panel (backend/admin/report.php), so all three show the same numbers.
// Sessions count on the day they started, in local time.

import {MONTHS, validColor} from './format.js';

export const PERIODS = [
    ['today', 'Oggi'],
    ['yesterday', 'Ieri'],
    ['week', 'Questa settimana'],
    ['lastWeek', 'Settimana scorsa'],
    ['month', 'Questo mese'],
    ['lastMonth', 'Mese scorso'],
    ['year', "Quest'anno"],
    ['lastYear', 'Anno scorso'],
    ['all', 'Tutto'],
    ['custom', 'Personalizzato'],
];

export const GROUPS = [
    ['auto', 'Automatico'],
    ['day', 'Giorno'],
    ['week', 'Settimana'],
    ['month', 'Mese'],
];

/** Category filter value meaning "tasks without a category". */
export const NO_CATEGORY = '__none__';

/** For "Senza categoria", "Altri task" and invalid stored colors. */
export const NEUTRAL = '#9ca3af';

export const defaultFilters = () => ({
    period: 'month', customFrom: null, customTo: null,
    categoryId: null, taskId: null, group: 'auto',
});

const day = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

/** [start, end) of the filtered period. */
export function periodRange(filters, now, firstSession = null) {
    const today = day(now);
    const monday = addDays(today, -((today.getDay() + 6) % 7));
    const y = now.getFullYear(), m = now.getMonth();
    switch (filters.period) {
    case 'today': return [today, addDays(today, 1)];
    case 'yesterday': return [addDays(today, -1), today];
    case 'week': return [monday, addDays(monday, 7)];
    case 'lastWeek': return [addDays(monday, -7), monday];
    case 'lastMonth': return [new Date(y, m - 1), new Date(y, m)];
    case 'year': return [new Date(y, 0), new Date(y + 1, 0)];
    case 'lastYear': return [new Date(y - 1, 0), new Date(y, 0)];
    case 'all': return [firstSession ? day(firstSession) : today, addDays(today, 1)];
    case 'custom':
        return [day(filters.customFrom ?? new Date(y, m)),
            addDays(day(filters.customTo ?? today), 1)];
    case 'month':
    default:
        return [new Date(y, m), new Date(y, m + 1)];
    }
}

/** `filters.group`, with "auto" resolved from the length of the range. */
export function effectiveGroup(filters, start, end) {
    if (filters.group && filters.group !== 'auto')
        return filters.group;
    const days = Math.round((end - start) / 86_400_000);
    if (days <= 45)
        return 'day';
    return days <= 190 ? 'week' : 'month';
}

function bucket(d, group) {
    if (group === 'week') {
        const monday = addDays(d, -((d.getDay() + 6) % 7));
        return [`w${monday.getFullYear()}-${monday.getMonth()}-${monday.getDate()}`,
            `${monday.getDate()} ${MONTHS[monday.getMonth()]}`];
    }
    if (group === 'month')
        return [`m${d.getFullYear()}-${d.getMonth()}`, `${MONTHS[d.getMonth()]} ${d.getFullYear()}`];
    return [`d${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`, `${d.getDate()} ${MONTHS[d.getMonth()]}`];
}

/**
 * @returns {{start, end, group, labels: string[],
 *   categories: {name, color, seconds, buckets: number[]}[],
 *   tasks: {name, category, color, seconds}[],
 *   sessions: object[], totalSeconds: number, activeDays: number}}
 */
export function buildReport(data, filters, now = new Date()) {
    const finished = data.sessions.filter(s => s.ended_at !== null);
    const first = finished.length
        ? new Date(Math.min(...finished.map(s => s.started_at))) : null;
    const [start, end] = periodRange(filters, now, first);
    const group = effectiveGroup(filters, start, end);

    // Every bucket of the range, empty ones included, in order.
    const index = new Map();
    const labels = [];
    for (let d = start; d < end; d = addDays(d, 1)) {
        const [key, label] = bucket(d, group);
        if (!index.has(key)) {
            index.set(key, labels.length);
            labels.push(label);
        }
    }

    const tasks = new Map(data.tasks.map(t => [t.id, t]));
    const categories = new Map(data.categories.map(c => [c.id, c]));
    const sessions = finished.filter(s => {
        if (s.started_at < start.getTime() || s.started_at >= end.getTime())
            return false;
        if (filters.taskId && s.task_id !== filters.taskId)
            return false;
        const catId = tasks.get(s.task_id)?.category_id ?? null;
        if (filters.categoryId === NO_CATEGORY)
            return catId === null;
        if (filters.categoryId)
            return catId === filters.categoryId;
        return true;
    }).sort((a, b) => b.started_at - a.started_at);

    const catName = key => key === NO_CATEGORY ? 'Senza categoria' : (categories.get(key)?.name ?? '?');
    const catColor = key => key === NO_CATEGORY ? NEUTRAL : (validColor(categories.get(key)?.color) ?? NEUTRAL);

    const perCat = new Map();
    const perTask = new Map();
    const days = new Set();
    let total = 0;
    for (const s of sessions) {
        const started = new Date(s.started_at);
        const catKey = tasks.get(s.task_id)?.category_id ?? NO_CATEGORY;
        if (!perCat.has(catKey))
            perCat.set(catKey, {seconds: 0, buckets: new Array(labels.length).fill(0)});
        const c = perCat.get(catKey);
        c.seconds += s.duration_seconds;
        const i = index.get(bucket(started, group)[0]);
        if (i !== undefined)
            c.buckets[i] += s.duration_seconds;
        const taskKey = s.task_id ?? '';
        perTask.set(taskKey, (perTask.get(taskKey) ?? 0) + s.duration_seconds);
        days.add(`${started.getFullYear()}-${started.getMonth()}-${started.getDate()}`);
        total += s.duration_seconds;
    }

    // Sorted by name: a category keeps its place whatever the filter.
    const series = [...perCat].map(([key, c]) => ({
        name: catName(key), color: catColor(key), seconds: c.seconds, buckets: c.buckets,
    })).sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

    const byTime = [...perTask].sort((a, b) => b[1] - a[1]);
    const top = byTime.slice(0, 10).map(([taskId, seconds]) => {
        const task = tasks.get(taskId);
        const catKey = task?.category_id ?? NO_CATEGORY;
        return {
            name: task ? (task.title || '(senza titolo)') : 'Senza task',
            category: catName(catKey), color: catColor(catKey), seconds,
        };
    });
    if (byTime.length > 10) {
        const rest = byTime.slice(10);
        top.push({name: `Altri ${rest.length} task`, category: '', color: NEUTRAL,
            seconds: rest.reduce((sum, [, s]) => sum + s, 0)});
    }

    return {start, end, group, labels, categories: series, tasks: top,
        sessions, totalSeconds: total, activeDays: days.size};
}
