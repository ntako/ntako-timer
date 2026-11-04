<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../lib/Presence.php';

$userId = Auth::requireAuth();
$pdo    = getDbConnection();

// Places edited on a device: allowed only while the user manages them.
if (Presence::effectiveSettings($pdo, $userId)['policy'] !== 'user') {
    http_response_code(403);
    echo json_encode(['error' => "I luoghi sono gestiti dall'amministratore"]);
    exit;
}

$body   = json_decode((string) file_get_contents('php://input'), true);
$places = (array) ($body['places'] ?? []);
if (count($places) > 100) {
    http_response_code(422);
    echo json_encode(['error' => 'Payload too large']);
    exit;
}

$pdo->beginTransaction();
try {
    $stored = Presence::upsertUserPlaces($pdo, $userId, array_values($places));
    $pdo->commit();
    echo json_encode(['synced' => $stored]);
} catch (InvalidArgumentException $e) {
    $pdo->rollBack();
    http_response_code(422);
    echo json_encode(['error' => $e->getMessage()]);
} catch (Throwable $e) {
    $pdo->rollBack();
    error_log('presence/places failed for user ' . $userId . ': ' . $e);
    http_response_code(500);
    echo json_encode(['error' => 'Saving places failed']);
}
