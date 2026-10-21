<?php

declare(strict_types=1);

// ── Security headers ──────────────────────────────────────────────────────────
header_remove('X-Powered-By');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: no-referrer');

// HSTS — only sent over HTTPS to avoid blocking plain-HTTP setups
if (
    (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ||
    (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https')
) {
    header('Strict-Transport-Security: max-age=31536000; includeSubDomains');
}

// ── CORS for Flutter web ──────────────────────────────────────────────────────
// Replace '*' with your actual domain once deployed, e.g.:
//   header('Access-Control-Allow-Origin: https://yourdomain.com');
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type, Authorization');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Vary: Origin');

// Last line of defence: anything uncaught is logged, and the client only gets
// a generic message (hosting defaults may have display_errors on).
ini_set('display_errors', '0');
set_exception_handler(static function (Throwable $e): void {
    error_log('Uncaught: ' . $e);
    if (!headers_sent()) {
        http_response_code(500);
    }
    echo json_encode(['error' => 'Internal server error']);
});

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$uri    = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];

// Strip everything up to and including /api/ — works whether the backend
// is installed at the domain root or in any subdirectory.
$route = ltrim((string) preg_replace('#^.*/api/#', '', $uri), '/');

match (true) {
    $method === 'POST' && $route === 'auth/register' => require __DIR__ . '/api/auth/register.php',
    $method === 'POST' && $route === 'auth/login'    => require __DIR__ . '/api/auth/login.php',
    $method === 'GET'  && $route === 'sync/pull'     => require __DIR__ . '/api/sync/pull.php',
    $method === 'POST' && $route === 'sync/push'     => require __DIR__ . '/api/sync/push.php',
    default => (function () {
        http_response_code(404);
        echo json_encode(['error' => 'Endpoint not found']);
    })(),
};
