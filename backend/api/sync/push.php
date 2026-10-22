<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../lib/SyncWriter.php';

$userId = Auth::requireAuth();

/** @var array{categories?:array<mixed>,tasks?:array<mixed>,sessions?:array<mixed>}|null $body */
$body       = json_decode((string) file_get_contents('php://input'), true);
$categories = (array) ($body['categories'] ?? []);
$tasks      = (array) ($body['tasks']      ?? []);
$sessions   = (array) ($body['sessions']   ?? []);

// ── Input validation ──────────────────────────────────────────────────────────
if (count($categories) > 100 || count($tasks) > 100 || count($sessions) > 500) {
    http_response_code(422);
    echo json_encode(['error' => 'Payload too large']);
    exit;
}

/** Validate UUID v4 format. */
$isUuid = static fn (string $s): bool =>
    (bool) preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i', $s);

foreach ($categories as $cat) {
    $cid  = (string) ($cat['client_id'] ?? '');
    $name = (string) ($cat['name']      ?? '');
    if (!$isUuid($cid) || strlen($name) === 0 || strlen($name) > 100) {
        http_response_code(422);
        echo json_encode(['error' => 'Invalid category data']);
        exit;
    }
}

foreach ($tasks as $task) {
    $cid   = (string) ($task['client_id'] ?? '');
    $title = (string) ($task['title']     ?? '');
    if (!$isUuid($cid) || strlen($title) > 255) {
        http_response_code(422);
        echo json_encode(['error' => 'Invalid task data']);
        exit;
    }
}

foreach ($sessions as $session) {
    $cid = (string) ($session['client_id'] ?? '');
    if (!$isUuid($cid)) {
        http_response_code(422);
        echo json_encode(['error' => 'Invalid session data']);
        exit;
    }
}
// ─────────────────────────────────────────────────────────────────────────────

$pdo = getDbConnection();
$pdo->beginTransaction();

try {
    $writer = new SyncWriter($pdo, $userId);
    $nowMs  = $writer->nowMs;

    $syncedCategories = $writer->upsertCategories($categories);
    $syncedTasks      = $writer->upsertTasks($tasks);

    // 1. Auto-close sessions orphaned by a crash: open for > 24 hours.
    $writer->closeOpenSessions('started_at < ?', [$nowMs - 86_400_000]);

    // Concurrent open sessions on different devices are legitimate: every
    // client shows the others' running timers and can stop them, so only
    // sessions left open by a crash (rule above) are closed here.

    $syncedSessions = $writer->upsertSessions($sessions);

    $writer->finish();
    $pdo->commit();

    echo json_encode([
        'synced_categories' => $syncedCategories,
        'synced_tasks'      => $syncedTasks,
        'synced_sessions'   => $syncedSessions,
    ]);
} catch (Throwable $e) {
    $pdo->rollBack();
    // Details go to the server log only: SQL errors reveal schema and data.
    error_log('sync/push failed for user ' . $userId . ': ' . $e);
    http_response_code(500);
    echo json_encode(['error' => 'Sync failed']);
}
