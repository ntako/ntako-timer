<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../middleware/RateLimit.php';

Auth::init();

// Allow 10 login attempts per IP per 10 minutes
if (!RateLimit::check('auth_login', 10, 600)) {
    RateLimit::tooManyRequests();
}

/** @var array<string,mixed>|null $body */
$body = json_decode((string) file_get_contents('php://input'), true);

$email    = trim((string) ($body['email'] ?? ''));
$password = (string) ($body['password'] ?? '');

$pdo  = getDbConnection();
$stmt = $pdo->prepare('SELECT id, password_hash FROM users WHERE email = ?');
$stmt->execute([$email]);

/** @var array{id:int,password_hash:string}|false $user */
$user = $stmt->fetch();

// Always run password_verify to prevent user enumeration via timing
if (!$user || !password_verify($password, $user['password_hash'])) {
    http_response_code(401);
    echo json_encode(['error' => 'Invalid credentials']);
    exit;
}

$token = Auth::encode([
    'sub' => $user['id'],
    'iat' => time(),
    'exp' => time() + 60 * 60 * 24 * 30, // 30 days
]);

echo json_encode([
    'token' => $token,
    'user'  => ['id' => $user['id'], 'email' => $email],
]);
