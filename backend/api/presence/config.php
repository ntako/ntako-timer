<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../lib/Presence.php';

$userId = Auth::requireAuth();
$pdo    = getDbConnection();

// What the user's devices need to detect presence. Small enough to be
// fetched whole every time: no cursor.
$settings = Presence::effectiveSettings($pdo, $userId);
$canEdit  = $settings['policy'] === 'user';

echo json_encode([
    'policy'      => $settings['policy'],
    // With policy "user" this is only the suggested mode: each device picks its own.
    'mode'        => $settings['mode'],
    'can_edit'    => $canEdit,
    'places'      => $settings['policy'] === 'off' ? [] : Presence::placesFor($pdo, $userId, $canEdit),
    'server_time' => (int) (microtime(true) * 1000),
]);
