<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';

$userId = Auth::requireAuth();

// `since` is a Unix timestamp in milliseconds; defaults to 0 (full sync)
$since = (int) ($_GET['since'] ?? 0);

$pdo = getDbConnection();

// Fetch categories modified after $since (includes soft-deleted records)
$stmt = $pdo->prepare('
    SELECT id, client_id, name, color, created_at, updated_at, deleted_at
    FROM categories
    WHERE user_id = ? AND updated_at > ?
    ORDER BY updated_at ASC
');
$stmt->execute([$userId, $since]);
$categories = $stmt->fetchAll();

foreach ($categories as &$c) {
    $c['id']         = (int) $c['id'];
    $c['created_at'] = (int) $c['created_at'];
    $c['updated_at'] = (int) $c['updated_at'];
    $c['deleted_at'] = $c['deleted_at'] !== null ? (int) $c['deleted_at'] : null;
}
unset($c);

// Fetch tasks modified after $since (includes soft-deleted records)
$stmt = $pdo->prepare('
    SELECT t.id, t.client_id, c.client_id AS category_client_id,
           t.title, t.description, t.is_completed,
           t.created_at, t.updated_at, t.deleted_at
    FROM tasks t
    LEFT JOIN categories c ON t.category_id = c.id
    WHERE t.user_id = ? AND t.updated_at > ?
    ORDER BY t.updated_at ASC
');
$stmt->execute([$userId, $since]);
$tasks = $stmt->fetchAll();

foreach ($tasks as &$t) {
    $t['id']           = (int) $t['id'];
    $t['is_completed'] = (int) $t['is_completed'];
    $t['created_at']   = (int) $t['created_at'];
    $t['updated_at']   = (int) $t['updated_at'];
    $t['deleted_at']   = $t['deleted_at'] !== null ? (int) $t['deleted_at'] : null;
}
unset($t);

// Fetch sessions created after $since
$stmt = $pdo->prepare('
    SELECT s.id, s.client_id, t.client_id AS task_client_id,
           s.type, s.started_at, s.ended_at, s.duration_seconds,
           s.is_completed, s.created_at
    FROM sessions s
    LEFT JOIN tasks t ON s.task_id = t.id
    WHERE s.user_id = ? AND s.created_at > ?
    ORDER BY s.id DESC LIMIT 30
');
$stmt->execute([$userId, $since]);
$sessions = $stmt->fetchAll();

foreach ($sessions as &$s) {
    $s['id']               = (int) $s['id'];
    $s['duration_seconds'] = (int) $s['duration_seconds'];
    $s['is_completed']     = (int) $s['is_completed'];
    $s['started_at']       = (int) $s['started_at'];
    $s['ended_at']         = $s['ended_at'] !== null ? (int) $s['ended_at'] : null;
    $s['created_at']       = (int) $s['created_at'];
}
unset($s);

echo json_encode([
    'categories'  => $categories,
    'tasks'       => $tasks,
    'sessions'    => $sessions,
    'server_time' => (int) (microtime(true) * 1000),
]);
