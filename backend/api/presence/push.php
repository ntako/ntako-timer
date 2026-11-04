<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../lib/Presence.php';

$userId = Auth::requireAuth();

$body      = json_decode((string) file_get_contents('php://input'), true);
$presences = (array) ($body['presences'] ?? []);
if (count($presences) > 500) {
    http_response_code(422);
    echo json_encode(['error' => 'Payload too large']);
    exit;
}

// Stays already recorded are accepted whatever the current policy: they
// were detected while it allowed them.
$pdo = getDbConnection();
$pdo->beginTransaction();
try {
    $synced = Presence::upsertPresences($pdo, $userId, array_values($presences));
    $pdo->commit();
    echo json_encode(['synced_presences' => $synced]);
} catch (InvalidArgumentException $e) {
    $pdo->rollBack();
    http_response_code(422);
    echo json_encode(['error' => $e->getMessage()]);
} catch (Throwable $e) {
    $pdo->rollBack();
    error_log('presence/push failed for user ' . $userId . ': ' . $e);
    http_response_code(500);
    echo json_encode(['error' => 'Sync failed']);
}
