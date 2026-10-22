<?php

declare(strict_types=1);

/**
 * Filtered time report for one user, for the admin panel user page.
 *
 * Same periods and grouping rules as the app's history
 * (lib/features/history/history_report.dart), so the numbers agree.
 */

const REPORT_PERIODS = [
    'today'      => 'Oggi',
    'yesterday'  => 'Ieri',
    'week'       => 'Questa settimana',
    'last_week'  => 'Settimana scorsa',
    'month'      => 'Questo mese',
    'last_month' => 'Mese scorso',
    'year'       => "Quest'anno",
    'last_year'  => 'Anno scorso',
    'all'        => 'Tutto',
    'custom'     => 'Personalizzato',
];

const REPORT_GROUPS = [
    'auto'  => 'Automatico',
    'day'   => 'Giorno',
    'week'  => 'Settimana',
    'month' => 'Mese',
];

const REPORT_MONTHS = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic'];

/** Color for rows without a category, and for invalid stored colors. */
const REPORT_NEUTRAL = '#9ca3af';

/**
 * Filters from the query string, validated.
 *
 * @param array<string,mixed> $q
 * @return array{period:string,from:DateTimeImmutable,to:DateTimeImmutable,
 *               cat:string,task:int,groupChoice:string,group:string}
 *         `to` is exclusive; `cat` is '' (all), 'none' or a category id.
 */
function reportFilters(array $q, PDO $pdo, int $userId): array
{
    $period = array_key_exists((string) ($q['period'] ?? ''), REPORT_PERIODS)
        ? (string) $q['period'] : 'month';
    $today = new DateTimeImmutable('today');

    [$from, $to] = match ($period) {
        'today'      => [$today, $today->modify('+1 day')],
        'yesterday'  => [$today->modify('-1 day'), $today],
        'week'       => [weekStart($today), weekStart($today)->modify('+7 days')],
        'last_week'  => [weekStart($today)->modify('-7 days'), weekStart($today)],
        'month'      => [$today->modify('first day of this month'), $today->modify('first day of next month')],
        'last_month' => [$today->modify('first day of last month'), $today->modify('first day of this month')],
        'year'       => [$today->setDate((int) $today->format('Y'), 1, 1), $today->setDate((int) $today->format('Y') + 1, 1, 1)],
        'last_year'  => [$today->setDate((int) $today->format('Y') - 1, 1, 1), $today->setDate((int) $today->format('Y'), 1, 1)],
        'all'        => [firstSessionDay($pdo, $userId) ?? $today, $today->modify('+1 day')],
        'custom'     => customRange($q) ?? [$today->modify('first day of this month'), $today->modify('first day of next month')],
    };

    $groupChoice = array_key_exists((string) ($q['group'] ?? ''), REPORT_GROUPS)
        ? (string) $q['group'] : 'auto';
    $days  = (int) $from->diff($to)->days;
    $group = $groupChoice !== 'auto' ? $groupChoice : ($days <= 45 ? 'day' : ($days <= 190 ? 'week' : 'month'));

    $cat = (string) ($q['cat'] ?? '');
    if ($cat !== 'none' && !ctype_digit($cat)) {
        $cat = '';
    }

    return [
        'period'      => $period,
        'from'        => $from,
        'to'          => $to,
        'cat'         => $cat,
        'task'        => max(0, (int) ($q['task'] ?? 0)),
        'groupChoice' => $groupChoice,
        'group'       => $group,
    ];
}

function weekStart(DateTimeImmutable $d): DateTimeImmutable
{
    return $d->modify('-' . ((int) $d->format('N') - 1) . ' days');
}

function firstSessionDay(PDO $pdo, int $userId): ?DateTimeImmutable
{
    $stmt = $pdo->prepare('SELECT MIN(started_at) FROM sessions WHERE user_id = ? AND ended_at IS NOT NULL');
    $stmt->execute([$userId]);
    $ms = $stmt->fetchColumn();
    return $ms ? (new DateTimeImmutable('@' . intdiv((int) $ms, 1000)))
        ->setTimezone(new DateTimeZone(date_default_timezone_get()))->setTime(0, 0) : null;
}

/** @return array{DateTimeImmutable,DateTimeImmutable}|null `from` .. `to` inclusive days → [from, to + 1 day) */
function customRange(array $q): ?array
{
    $parse = static function ($v): ?DateTimeImmutable {
        $d = DateTimeImmutable::createFromFormat('!Y-m-d', (string) $v);
        return $d ?: null;
    };
    $from = $parse($q['from'] ?? '');
    $to   = $parse($q['to'] ?? '');
    if ($from === null || $to === null) {
        return null;
    }
    if ($from > $to) {
        [$from, $to] = [$to, $from];
    }
    return [$from, $to->modify('+1 day')];
}

/** @return array{key:string,label:string} bucket of $d for $group */
function reportBucket(DateTimeImmutable $d, string $group): array
{
    $month = REPORT_MONTHS[(int) $d->format('n') - 1];
    return match ($group) {
        'week'  => (static function () use ($d) {
            $start = weekStart($d);
            return ['key' => $start->format('Y-m-d'),
                    'label' => $start->format('j') . ' ' . REPORT_MONTHS[(int) $start->format('n') - 1]];
        })(),
        'month' => ['key' => $d->format('Y-m'), 'label' => $month . ' ' . $d->format('Y')],
        default => ['key' => $d->format('Y-m-d'), 'label' => $d->format('j') . ' ' . $month],
    };
}

function validColor(?string $c): string
{
    return $c !== null && preg_match('/^#[0-9a-f]{6}$/i', $c) ? $c : REPORT_NEUTRAL;
}

/**
 * Finished sessions in the filtered range, aggregated for list and charts.
 * Sessions are assigned to the day they started on (server timezone).
 *
 * @param array<string,mixed> $f result of reportFilters()
 * @return array<string,mixed>
 */
function buildReport(PDO $pdo, int $userId, array $f): array
{
    $sql = '
        SELECT s.started_at, s.duration_seconds,
               t.id AS task_id, t.title AS task_title, t.is_completed, t.deleted_at,
               c.id AS cat_id, c.name AS cat_name, c.color AS cat_color
        FROM sessions s
        LEFT JOIN tasks t      ON t.id = s.task_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE s.user_id = ? AND s.ended_at IS NOT NULL
          AND s.started_at >= ? AND s.started_at < ?';
    $params = [$userId, $f['from']->getTimestamp() * 1000, $f['to']->getTimestamp() * 1000];
    if ($f['cat'] === 'none') {
        $sql .= ' AND c.id IS NULL';
    } elseif ($f['cat'] !== '') {
        $sql .= ' AND c.id = ?';
        $params[] = (int) $f['cat'];
    }
    if ($f['task'] > 0) {
        $sql .= ' AND t.id = ?';
        $params[] = $f['task'];
    }
    $stmt = $pdo->prepare($sql . ' ORDER BY s.started_at');
    $stmt->execute($params);

    // Every bucket of the range, empty ones included, in order.
    $buckets = [];
    for ($d = $f['from']; $d < $f['to']; $d = $d->modify('+1 day')) {
        $b = reportBucket($d, $f['group']);
        $buckets[$b['key']] ??= $b['label'];
    }
    $bucketIndex = array_flip(array_keys($buckets));

    $cats   = [];   // cat key → name, color, seconds, per-bucket seconds
    $tasks  = [];   // task key → row for the list (groupByCategory format)
    $days   = [];
    $total  = 0;
    $count  = 0;
    $tz     = new DateTimeZone(date_default_timezone_get());

    foreach ($stmt->fetchAll() as $s) {
        $secs  = (int) $s['duration_seconds'];
        $start = (new DateTimeImmutable('@' . intdiv((int) $s['started_at'], 1000)))->setTimezone($tz);
        $catKey  = $s['cat_id'] !== null ? (int) $s['cat_id'] : 0;
        $taskKey = $s['task_id'] !== null ? (int) $s['task_id'] : 0;

        $cats[$catKey] ??= [
            'name'    => $s['cat_name'] ?? 'Senza categoria',
            'color'   => $s['cat_id'] !== null ? validColor($s['cat_color']) : REPORT_NEUTRAL,
            'seconds' => 0,
            'buckets' => array_fill(0, count($buckets), 0),
        ];
        $cats[$catKey]['seconds'] += $secs;
        $i = $bucketIndex[reportBucket($start, $f['group'])['key']] ?? null;
        if ($i !== null) {
            $cats[$catKey]['buckets'][$i] += $secs;
        }

        $tasks[$taskKey] ??= [
            'cat_id'        => $catKey,
            'cat_name'      => $cats[$catKey]['name'],
            'cat_color'     => $cats[$catKey]['color'],
            'task_id'       => $taskKey,
            'task_title'    => $s['task_title'] ?? 'Senza task',
            'is_completed'  => (int) ($s['is_completed'] ?? 0),
            'deleted_at'    => $s['deleted_at'],
            'session_count' => 0,
            'total_seconds' => 0,
            'first_ms'      => (int) $s['started_at'],
            'last_ms'       => (int) $s['started_at'],
        ];
        $tasks[$taskKey]['session_count']++;
        $tasks[$taskKey]['total_seconds'] += $secs;
        $tasks[$taskKey]['last_ms'] = (int) $s['started_at'];

        $days[$start->format('Y-m-d')] = true;
        $total += $secs;
        $count++;
    }

    // Stable order by name: a category keeps its place whatever the filter.
    uasort($cats, static fn ($a, $b) => strcasecmp($a['name'], $b['name']));
    $rows = array_values($tasks);
    usort($rows, static fn ($a, $b) => strcasecmp($a['cat_name'], $b['cat_name'])
        ?: strcasecmp((string) $a['task_title'], (string) $b['task_title']));

    // Top tasks for the bar chart; the tail folds into one "others" bar.
    $byTime = $rows;
    usort($byTime, static fn ($a, $b) => $b['total_seconds'] <=> $a['total_seconds']);
    $top = array_map(static fn ($t) => [
        'name'     => $t['task_title'],
        'category' => $t['cat_name'],
        'color'    => $t['cat_color'],
        'seconds'  => $t['total_seconds'],
    ], array_slice($byTime, 0, 10));
    $rest = array_slice($byTime, 10);
    if ($rest) {
        $top[] = [
            'name'     => 'Altri ' . count($rest) . ' task',
            'category' => '',
            'color'    => REPORT_NEUTRAL,
            'seconds'  => array_sum(array_column($rest, 'total_seconds')),
        ];
    }

    return [
        'total_seconds' => $total,
        'sessions'      => $count,
        'active_days'   => count($days),
        'rows'          => $rows,
        'chart'         => [
            'labels'     => array_values($buckets),
            'categories' => array_values(array_map(static fn ($c) => [
                'name'    => $c['name'],
                'color'   => $c['color'],
                'seconds' => $c['seconds'],
                'buckets' => $c['buckets'],
            ], $cats)),
            'tasks'      => $top,
        ],
    ];
}
