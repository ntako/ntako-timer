<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../lib/Presence.php';

$userId = Auth::requireAuth();
$pdo    = getDbConnection();

// Stays of every device of the user, for the app's presence report.
// `from`/`to` in ms; at most 10000 rows (years of daily stays).
$from = max(0, (int) ($_GET['from'] ?? 0));
$to   = (int) ($_GET['to'] ?? 0) ?: (int) (microtime(true) * 1000) + 86_400_000;

echo json_encode([
    'stays'       => Presence::stays($pdo, $userId, $from, $to),
    'first_ms'    => Presence::firstStayMs($pdo, $userId),
    'server_time' => (int) (microtime(true) * 1000),
]);
