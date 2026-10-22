// Formatting shared by the panel menu and the preferences window.
// Same conventions as the app (lib/features/history/history_report.dart).

export const MONTHS = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu',
    'lug', 'ago', 'set', 'ott', 'nov', 'dic'];

/** 3725 → "1h 02m", 300 → "5m" (rounded to the minute). */
export function formatHours(seconds) {
    const minutes = Math.round(seconds / 60);
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

/** 3725 → "1:02:05": the running timer in the top bar. */
export function formatClock(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600);
    const m = String(Math.floor(s % 3600 / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    return h > 0 ? `${h}:${m}:${ss}` : `${m}:${ss}`;
}

/** Date → "1 ott 2026". */
export function formatDay(d) {
    return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

/** Date → "14:05". */
export function formatTime(d) {
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** "#rrggbb" or null when invalid. */
export function validColor(hex) {
    return typeof hex === 'string' && /^#[0-9a-f]{6}$/i.test(hex) ? hex : null;
}

/** "#rrggbb" → [r, g, b] in 0..1 for cairo; neutral grey when invalid. */
export function colorToRgb(hex) {
    const c = validColor(hex) ?? '#9ca3af';
    return [1, 3, 5].map(i => parseInt(c.slice(i, i + 2), 16) / 255);
}

/** Same palette as the app's category picker. */
export const CATEGORY_COLORS = [
    '#6366f1', '#ec4899', '#f59e0b', '#10b981',
    '#3b82f6', '#ef4444', '#8b5cf6', '#6b7280',
];
