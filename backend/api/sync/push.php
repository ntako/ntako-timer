<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';

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

$allowedSessionTypes = ['work', 'short_break', 'long_break', 'tracking'];
$allowedTaskTypes    = ['pomodoro', 'tracker'];

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
    $type  = (string) ($task['type']      ?? 'pomodoro');
    if (!$isUuid($cid) || strlen($title) > 255 || !in_array($type, $allowedTaskTypes, true)) {
        http_response_code(422);
        echo json_encode(['error' => 'Invalid task data']);
        exit;
    }
}

foreach ($sessions as $session) {
    $cid  = (string) ($session['client_id'] ?? '');
    $type = (string) ($session['type']      ?? '');
    if (!$isUuid($cid) || !in_array($type, $allowedSessionTypes, true)) {
        http_response_code(422);
        echo json_encode(['error' => 'Invalid session data']);
        exit;
    }
}
// ─────────────────────────────────────────────────────────────────────────────

$pdo = getDbConnection();
$pdo->beginTransaction();

try {
    $syncedCategories = [];
    $syncedTasks      = [];
    $syncedSessions   = [];

    // ----------------------------------------------------------------
    // Upsert categories — last-write-wins on updated_at
    // ----------------------------------------------------------------
    $catUpsert = $pdo->prepare('
        INSERT INTO categories
            (user_id, client_id, name, color, created_at, updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            name       = IF(VALUES(updated_at) > updated_at, VALUES(name),       name),
            color      = IF(VALUES(updated_at) > updated_at, VALUES(color),      color),
            deleted_at = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at), deleted_at),
            updated_at = IF(VALUES(updated_at) > updated_at, VALUES(updated_at), updated_at)
    ');

    $getCatId = $pdo->prepare(
        'SELECT id FROM categories WHERE user_id = ? AND client_id = ?'
    );

    foreach ($categories as $cat) {
        $clientId = (string) ($cat['client_id'] ?? '');
        if ($clientId === '') {
            continue;
        }

        $catUpsert->execute([
            $userId,
            $clientId,
            (string) ($cat['name']  ?? ''),
            (string) ($cat['color'] ?? '#6366f1'),
            (int) ($cat['created_at'] ?? 0),
            (int) ($cat['updated_at'] ?? 0),
            isset($cat['deleted_at']) ? (int) $cat['deleted_at'] : null,
        ]);

        $getCatId->execute([$userId, $clientId]);
        /** @var array{id:int}|false $row */
        $row = $getCatId->fetch();
        if ($row !== false) {
            $syncedCategories[] = [
                'client_id' => $clientId,
                'server_id' => (int) $row['id'],
            ];
        }
    }

    // Build a client_id → server_id map for categories
    $catIdMap = [];
    foreach ($syncedCategories as $sc) {
        $catIdMap[$sc['client_id']] = $sc['server_id'];
    }

    // ----------------------------------------------------------------
    // Upsert tasks — last-write-wins on updated_at
    // ----------------------------------------------------------------
    $taskUpsert = $pdo->prepare('
        INSERT INTO tasks
            (user_id, client_id, category_id, title, description, type,
             pomodoro_goal, pomodoros_done, is_completed, created_at, updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            category_id    = IF(VALUES(updated_at) > updated_at, VALUES(category_id),    category_id),
            title          = IF(VALUES(updated_at) > updated_at, VALUES(title),           title),
            description    = IF(VALUES(updated_at) > updated_at, VALUES(description),     description),
            type           = IF(VALUES(updated_at) > updated_at, VALUES(type),            type),
            pomodoro_goal  = IF(VALUES(updated_at) > updated_at, VALUES(pomodoro_goal),   pomodoro_goal),
            pomodoros_done = IF(VALUES(updated_at) > updated_at, VALUES(pomodoros_done),  pomodoros_done),
            is_completed   = IF(VALUES(updated_at) > updated_at, VALUES(is_completed),    is_completed),
            deleted_at     = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at),      deleted_at),
            updated_at     = IF(VALUES(updated_at) > updated_at, VALUES(updated_at),      updated_at)
    ');

    $getTaskId = $pdo->prepare(
        'SELECT id FROM tasks WHERE user_id = ? AND client_id = ?'
    );

    foreach ($tasks as $task) {
        $clientId = (string) ($task['client_id'] ?? '');
        if ($clientId === '') {
            continue;
        }

        // Resolve category server-id from map or prior sync
        $categoryServerId = null;
        $catClientId = (string) ($task['category_client_id'] ?? '');
        if ($catClientId !== '') {
            if (isset($catIdMap[$catClientId])) {
                $categoryServerId = $catIdMap[$catClientId];
            } else {
                $lookupStmt = $pdo->prepare(
                    'SELECT id FROM categories WHERE user_id = ? AND client_id = ?'
                );
                $lookupStmt->execute([$userId, $catClientId]);
                /** @var array{id:int}|false $lookupRow */
                $lookupRow        = $lookupStmt->fetch();
                $categoryServerId = $lookupRow ? (int) $lookupRow['id'] : null;
            }
        }

        $taskUpsert->execute([
            $userId,
            $clientId,
            $categoryServerId,
            (string) ($task['title'] ?? ''),
            isset($task['description']) ? (string) $task['description'] : null,
            (string) ($task['type'] ?? 'pomodoro'),
            (int) ($task['pomodoro_goal']  ?? 4),
            (int) ($task['pomodoros_done'] ?? 0),
            (int) ($task['is_completed']   ?? 0),
            (int) ($task['created_at']     ?? 0),
            (int) ($task['updated_at']     ?? 0),
            isset($task['deleted_at']) ? (int) $task['deleted_at'] : null,
        ]);

        $getTaskId->execute([$userId, $clientId]);
        /** @var array{id:int}|false $row */
        $row = $getTaskId->fetch();
        if ($row !== false) {
            $syncedTasks[] = [
                'client_id' => $clientId,
                'server_id' => (int) $row['id'],
            ];
        }
    }

    // Build a client_id → server_id map for tasks (needed by sessions)
    $taskIdMap = [];
    foreach ($syncedTasks as $st) {
        $taskIdMap[$st['client_id']] = $st['server_id'];
    }

    // ----------------------------------------------------------------
    // Upsert sessions — append-only (sessions are immutable once complete)
    // ----------------------------------------------------------------

    $nowMs = (int) (microtime(true) * 1000);

    // 1. Auto-close sessions orphaned by a crash: open for > 24 hours.
    $pdo->prepare('
        UPDATE sessions
        SET    ended_at = ?, is_completed = 0
        WHERE  user_id = ? AND ended_at IS NULL AND started_at < ?
    ')->execute([$nowMs, $userId, $nowMs - 86_400_000]);

    // 2. If the push contains a currently-open session, close every other
    //    open session for this user that is NOT in the payload.
    //    (Handles sessions that were synced on start but never completed.)
    $openInPayload = array_filter($sessions, fn($s) => !isset($s['ended_at']));
    if (!empty($openInPayload)) {
        $pushedIds    = array_map(fn($s) => (string) ($s['client_id'] ?? ''), $sessions);
        $ph           = implode(',', array_fill(0, count($pushedIds), '?'));
        $pdo->prepare("
            UPDATE sessions
            SET    ended_at = ?, is_completed = 0
            WHERE  user_id = ? AND ended_at IS NULL AND client_id NOT IN ($ph)
        ")->execute([$nowMs, $userId, ...$pushedIds]);
    }

    $sessionUpsert = $pdo->prepare('
        INSERT INTO sessions
            (user_id, task_id, client_id, type, started_at, ended_at,
             duration_seconds, is_completed, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            ended_at     = COALESCE(ended_at, VALUES(ended_at)),
            is_completed = IF(is_completed = 0, VALUES(is_completed), is_completed)
    ');

    $getSessionId = $pdo->prepare(
        'SELECT id FROM sessions WHERE user_id = ? AND client_id = ?'
    );

    foreach ($sessions as $session) {
        $clientId = (string) ($session['client_id'] ?? '');
        if ($clientId === '') {
            continue;
        }

        $sessionType = (string) ($session['type'] ?? 'work');

        // Resolve task server-id AND type from the map or from the DB.
        $taskServerId = null;
        $taskType     = null;
        $taskClientId = (string) ($session['task_client_id'] ?? '');
        if ($taskClientId !== '') {
            if (isset($taskIdMap[$taskClientId])) {
                $taskServerId = $taskIdMap[$taskClientId];
                // Find the task type from the current push payload.
                foreach ($tasks as $t) {
                    if ((string) ($t['client_id'] ?? '') === $taskClientId) {
                        $taskType = (string) ($t['type'] ?? 'pomodoro');
                        break;
                    }
                }
            }
            if ($taskServerId === null) {
                $lookupStmt = $pdo->prepare(
                    'SELECT id, type FROM tasks WHERE user_id = ? AND client_id = ?'
                );
                $lookupStmt->execute([$userId, $taskClientId]);
                /** @var array{id:int,type:string}|false $lookupRow */
                $lookupRow = $lookupStmt->fetch();
                if ($lookupRow !== false) {
                    $taskServerId = (int) $lookupRow['id'];
                    $taskType     = (string) $lookupRow['type'];
                }
            }

            // Validate cross-association: session type must be compatible with task type.
            // break/long_break sessions are not tied to a specific task type.
            if ($taskType !== null) {
                if ($sessionType === 'tracking' && $taskType !== 'tracker') {
                    throw new \InvalidArgumentException(
                        "Session '$clientId': type 'tracking' is only valid for tracker tasks"
                    );
                }
                if ($sessionType === 'work' && $taskType !== 'pomodoro') {
                    throw new \InvalidArgumentException(
                        "Session '$clientId': type 'work' is only valid for pomodoro tasks"
                    );
                }
            }
        }

        $sessionUpsert->execute([
            $userId,
            $taskServerId,
            $clientId,
            $sessionType,
            (int) ($session['started_at']       ?? 0),
            isset($session['ended_at']) ? (int) $session['ended_at'] : null,
            (int) ($session['duration_seconds'] ?? 0),
            (int) ($session['is_completed']     ?? 0),
            (int) ($session['created_at']       ?? 0),
        ]);

        $getSessionId->execute([$userId, $clientId]);
        /** @var array{id:int}|false $row */
        $row = $getSessionId->fetch();
        if ($row !== false) {
            $syncedSessions[] = [
                'client_id' => $clientId,
                'server_id' => (int) $row['id'],
            ];
        }
    }

    $pdo->commit();

    echo json_encode([
        'synced_categories' => $syncedCategories,
        'synced_tasks'      => $syncedTasks,
        'synced_sessions'   => $syncedSessions,
    ]);
} catch (\InvalidArgumentException $e) {
    $pdo->rollBack();
    http_response_code(422);
    echo json_encode(['error' => $e->getMessage()]);
} catch (Exception $e) {
    $pdo->rollBack();
    http_response_code(500);
    echo json_encode(['error' => 'Sync failed: ' . $e->getMessage()]);
}
