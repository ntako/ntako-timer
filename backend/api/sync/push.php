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
    $syncedCategories = [];
    $syncedTasks      = [];
    $syncedSessions   = [];

    $nowMs = (int) (microtime(true) * 1000);

    // Devices without NTP (Cardputer offline) send timestamps near epoch 0.
    // Replace them with server time so last-write-wins stays meaningful.
    $minValidMs = 946_684_800_000; // 2000-01-01 in ms
    $validTs = static fn (int $ms): int => $ms < $minValidMs ? $nowMs : $ms;

    // Every row written gets the next value of a per-user counter, which
    // incremental pull uses as its cursor. Locking the user row here also
    // serialises concurrent pushes, so versions commit in increasing order
    // and a pull can never skip a row that committed late.
    $seqStmt = $pdo->prepare('SELECT sync_seq FROM users WHERE id = ? FOR UPDATE');
    $seqStmt->execute([$userId]);
    $seq = (int) $seqStmt->fetchColumn();
    $nextVersion = static function () use (&$seq): int {
        return ++$seq;
    };

    // ----------------------------------------------------------------
    // Upsert categories — last-write-wins on updated_at
    // ----------------------------------------------------------------
    $catUpsert = $pdo->prepare('
        INSERT INTO categories
            (user_id, client_id, name, color, created_at, updated_at, deleted_at, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            name       = IF(VALUES(updated_at) > updated_at, VALUES(name),       name),
            color      = IF(VALUES(updated_at) > updated_at, VALUES(color),      color),
            deleted_at = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at), deleted_at),
            version    = IF(VALUES(updated_at) > updated_at, VALUES(version),    version),
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
            $validTs((int) ($cat['created_at'] ?? 0)),
            $validTs((int) ($cat['updated_at'] ?? 0)),
            isset($cat['deleted_at']) ? $validTs((int) $cat['deleted_at']) : null,
            $nextVersion(),
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
             is_completed, created_at, updated_at, deleted_at, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            category_id    = IF(VALUES(updated_at) > updated_at, VALUES(category_id),    category_id),
            title          = IF(VALUES(updated_at) > updated_at, VALUES(title),           title),
            description    = IF(VALUES(updated_at) > updated_at, VALUES(description),     description),
            is_completed   = IF(VALUES(updated_at) > updated_at, VALUES(is_completed),    is_completed),
            deleted_at     = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at),      deleted_at),
            version        = IF(VALUES(updated_at) > updated_at, VALUES(version),         version),
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
            'tracker',
            (int) ($task['is_completed'] ?? 0),
            $validTs((int) ($task['created_at'] ?? 0)),
            $validTs((int) ($task['updated_at'] ?? 0)),
            isset($task['deleted_at']) ? $validTs((int) $task['deleted_at']) : null,
            $nextVersion(),
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

    // Closing a session is a change other devices must see, so each closed
    // row gets its own version.
    $closeSession = $pdo->prepare(
        'UPDATE sessions SET ended_at = ?, is_completed = 0, version = ? WHERE id = ?'
    );
    $closeOpenSessions = static function (PDOStatement $find, array $params) use (
        $closeSession, $nextVersion, $nowMs
    ): void {
        $find->execute($params);
        foreach ($find->fetchAll(PDO::FETCH_COLUMN) as $id) {
            $closeSession->execute([$nowMs, $nextVersion(), (int) $id]);
        }
    };

    // 1. Auto-close sessions orphaned by a crash: open for > 24 hours.
    $closeOpenSessions($pdo->prepare('
        SELECT id FROM sessions
        WHERE  user_id = ? AND ended_at IS NULL AND started_at < ?
    '), [$userId, $nowMs - 86_400_000]);

    // 2. If the push contains a currently-open session, close other open sessions
    //    for this user that are NOT in the payload AND are older than 4 hours.
    //    The age guard prevents closing a legitimate concurrent session on another
    //    device (e.g. Flutter tracking while Cardputer syncs its own open session).
    $openInPayload = array_filter($sessions, fn($s) => !isset($s['ended_at']));
    if (!empty($openInPayload)) {
        $pushedIds    = array_map(fn($s) => (string) ($s['client_id'] ?? ''), $sessions);
        $ph           = implode(',', array_fill(0, count($pushedIds), '?'));
        $closeOpenSessions($pdo->prepare("
            SELECT id FROM sessions
            WHERE  user_id = ? AND ended_at IS NULL AND client_id NOT IN ($ph)
              AND  started_at < ?
        "), [$userId, ...$pushedIds, $nowMs - 14_400_000]); // 4 h
    }

    $sessionUpsert = $pdo->prepare('
        INSERT INTO sessions
            (user_id, task_id, client_id, type, started_at, ended_at,
             duration_seconds, is_completed, created_at, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            ended_at         = COALESCE(ended_at, VALUES(ended_at)),
            duration_seconds = GREATEST(duration_seconds, VALUES(duration_seconds)),
            is_completed     = IF(is_completed = 0, VALUES(is_completed), is_completed),
            created_at       = IF(created_at = 0, VALUES(created_at), created_at),
            version          = VALUES(version)
    ');

    $getSessionId = $pdo->prepare(
        'SELECT id FROM sessions WHERE user_id = ? AND client_id = ?'
    );

    foreach ($sessions as $session) {
        $clientId = (string) ($session['client_id'] ?? '');
        if ($clientId === '') {
            continue;
        }

        // Resolve task server-id from the map or from the DB.
        $taskServerId = null;
        $taskClientId = (string) ($session['task_client_id'] ?? '');
        if ($taskClientId !== '') {
            if (isset($taskIdMap[$taskClientId])) {
                $taskServerId = $taskIdMap[$taskClientId];
            } else {
                $lookupStmt = $pdo->prepare(
                    'SELECT id FROM tasks WHERE user_id = ? AND client_id = ?'
                );
                $lookupStmt->execute([$userId, $taskClientId]);
                /** @var array{id:int}|false $lookupRow */
                $lookupRow = $lookupStmt->fetch();
                if ($lookupRow !== false) {
                    $taskServerId = (int) $lookupRow['id'];
                }
            }
        }

        $startedAt   = (int) ($session['started_at']       ?? 0);
        $endedAt     = isset($session['ended_at']) ? (int) $session['ended_at'] : null;
        $durationSec = (int) ($session['duration_seconds'] ?? 0);

        // Offline sessions have no NTP: started_at will be near epoch 0.
        // Reconstruct timestamps from server time so history is usable.
        if ($startedAt < $minValidMs) {
            $endedAt   = $nowMs;
            $startedAt = $nowMs - $durationSec * 1000;
        }

        $sessionUpsert->execute([
            $userId,
            $taskServerId,
            $clientId,
            'tracking',
            $startedAt,
            $endedAt,
            $durationSec,
            (int) ($session['is_completed'] ?? 0),
            $nowMs,  // always server time: ensures pull.php (created_at > since) finds it
            $nextVersion(),
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

    $pdo->prepare('UPDATE users SET sync_seq = ? WHERE id = ?')->execute([$seq, $userId]);

    $pdo->commit();

    echo json_encode([
        'synced_categories' => $syncedCategories,
        'synced_tasks'      => $syncedTasks,
        'synced_sessions'   => $syncedSessions,
    ]);
} catch (Exception $e) {
    $pdo->rollBack();
    http_response_code(500);
    echo json_encode(['error' => 'Sync failed: ' . $e->getMessage()]);
}
