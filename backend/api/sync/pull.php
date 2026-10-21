<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';

$userId = Auth::requireAuth();

$pdo = getDbConnection();

$castCategory = static function (array $c): array {
    $c['id']         = (int) $c['id'];
    $c['created_at'] = (int) $c['created_at'];
    $c['updated_at'] = (int) $c['updated_at'];
    $c['deleted_at'] = $c['deleted_at'] !== null ? (int) $c['deleted_at'] : null;
    return $c;
};

$castTask = static function (array $t): array {
    $t['id']           = (int) $t['id'];
    $t['is_completed'] = (int) $t['is_completed'];
    $t['created_at']   = (int) $t['created_at'];
    $t['updated_at']   = (int) $t['updated_at'];
    $t['deleted_at']   = $t['deleted_at'] !== null ? (int) $t['deleted_at'] : null;
    return $t;
};

$castSession = static function (array $s): array {
    $s['id']               = (int) $s['id'];
    $s['duration_seconds'] = (int) $s['duration_seconds'];
    $s['is_completed']     = (int) $s['is_completed'];
    $s['started_at']       = (int) $s['started_at'];
    $s['ended_at']         = $s['ended_at'] !== null ? (int) $s['ended_at'] : null;
    $s['created_at']       = (int) $s['created_at'];
    return $s;
};

$categorySql = '
    SELECT id, client_id, name, color, created_at, updated_at, deleted_at, version
    FROM categories
    WHERE user_id = ? AND %s
    ORDER BY %s
';

$taskSql = '
    SELECT t.id, t.client_id, c.client_id AS category_client_id,
           t.title, t.description, t.is_completed,
           t.created_at, t.updated_at, t.deleted_at, t.version
    FROM tasks t
    LEFT JOIN categories c ON t.category_id = c.id
    WHERE t.user_id = ? AND %s
    ORDER BY %s
';

$sessionSql = '
    SELECT s.id, s.client_id, t.client_id AS task_client_id,
           s.type, s.started_at, s.ended_at, s.duration_seconds,
           s.is_completed, s.created_at, s.version
    FROM sessions s
    LEFT JOIN tasks t ON s.task_id = t.id
    WHERE s.user_id = ? AND %s
    ORDER BY %s
';

if (isset($_GET['cursor'])) {
    // ── Incremental mode ──────────────────────────────────────────────────────
    // Returns every row whose version is above `cursor`, a page at a time.
    // Versions come from the server-side per-user counter (see push.php), so
    // client clock skew can't hide a change. The client stores the returned
    // `cursor` and calls again while `has_more` is true.
    $cursor = max(0, (int) $_GET['cursor']);
    $limit  = max(1, min(500, (int) ($_GET['limit'] ?? 200)));

    // One snapshot for the counter and all three tables.
    $pdo->beginTransaction();

    $seqStmt = $pdo->prepare('SELECT sync_seq FROM users WHERE id = ?');
    $seqStmt->execute([$userId]);
    $head = (int) $seqStmt->fetchColumn();

    // A cursor ahead of the server (e.g. database restored from a backup)
    // would never match anything again: start over with a full sync.
    if ($cursor > $head) {
        $cursor = 0;
    }

    $fetch = static function (string $sql, string $alias) use ($pdo, $userId, $cursor, $limit): array {
        $stmt = $pdo->prepare(
            sprintf($sql, "{$alias}version > ?", "{$alias}version ASC") . " LIMIT $limit"
        );
        $stmt->execute([$userId, $cursor]);
        return $stmt->fetchAll();
    };

    $pages = [
        'categories' => $fetch($categorySql, ''),
        'tasks'      => $fetch($taskSql, 't.'),
        'sessions'   => $fetch($sessionSql, 's.'),
    ];

    $pdo->commit();

    // A full page may have more rows behind it, so the new cursor can only
    // advance to the lowest last-version among full pages. Rows above it from
    // the other tables are dropped here and come back on the next page.
    $next    = $head;
    $hasMore = false;
    foreach ($pages as $rows) {
        if (count($rows) === $limit) {
            $hasMore = true;
            $next    = min($next, (int) $rows[$limit - 1]['version']);
        }
    }

    $page = static function (array $rows, callable $cast) use ($next): array {
        $out = [];
        foreach ($rows as $row) {
            if ((int) $row['version'] <= $next) {
                unset($row['version']);
                $out[] = $cast($row);
            }
        }
        return $out;
    };

    echo json_encode([
        'categories'  => $page($pages['categories'], $castCategory),
        'tasks'       => $page($pages['tasks'], $castTask),
        'sessions'    => $page($pages['sessions'], $castSession),
        'cursor'      => $next,
        'has_more'    => $hasMore,
        'server_time' => (int) (microtime(true) * 1000),
    ]);
    return;
}

// ── Snapshot mode (`since`) ───────────────────────────────────────────────────
// Used by the Cardputer, which calls with since=0 and treats the response as
// the full current state: every category and task, plus the 30 most recent
// sessions for its on-device log.
$since = (int) ($_GET['since'] ?? 0);

$strip = static function (array $row): array {
    unset($row['version']);
    return $row;
};

$stmt = $pdo->prepare(sprintf($categorySql, 'updated_at > ?', 'updated_at ASC'));
$stmt->execute([$userId, $since]);
$categories = array_map(static fn ($c) => $castCategory($strip($c)), $stmt->fetchAll());

$stmt = $pdo->prepare(sprintf($taskSql, 't.updated_at > ?', 't.updated_at ASC'));
$stmt->execute([$userId, $since]);
$tasks = array_map(static fn ($t) => $castTask($strip($t)), $stmt->fetchAll());

$stmt = $pdo->prepare(sprintf($sessionSql, 's.created_at > ?', 's.id DESC') . ' LIMIT 30');
$stmt->execute([$userId, $since]);
$sessions = array_map(static fn ($s) => $castSession($strip($s)), $stmt->fetchAll());

echo json_encode([
    'categories'  => $categories,
    'tasks'       => $tasks,
    'sessions'    => $sessions,
    'server_time' => (int) (microtime(true) * 1000),
]);
