<?php

declare(strict_types=1);

require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../middleware/Auth.php';
require_once __DIR__ . '/../../middleware/RateLimit.php';

Auth::init();

// Allow 5 registrations per IP per hour
if (!RateLimit::check('auth_register', 5, 3600)) {
    RateLimit::tooManyRequests();
}

/** @var array<string,mixed>|null $body */
$body = json_decode((string) file_get_contents('php://input'), true);

$email    = trim((string) ($body['email'] ?? ''));
$password = (string) ($body['password'] ?? '');

if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    http_response_code(422);
    echo json_encode(['error' => 'Invalid email address']);
    exit;
}

if (strlen($password) < 8) {
    http_response_code(422);
    echo json_encode(['error' => 'Password must be at least 8 characters']);
    exit;
}

$pdo  = getDbConnection();
$stmt = $pdo->prepare('SELECT id FROM users WHERE email = ?');
$stmt->execute([$email]);

if ($stmt->fetch()) {
    http_response_code(409);
    echo json_encode(['error' => 'Email already registered']);
    exit;
}

$hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
$stmt = $pdo->prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)');
$stmt->execute([$email, $hash]);
$userId = (int) $pdo->lastInsertId();

$token = Auth::encode([
    'sub' => $userId,
    'iat' => time(),
    'exp' => time() + 60 * 60 * 24 * 30, // 30 days
]);

http_response_code(201);
echo json_encode([
    'token' => $token,
    'user'  => ['id' => $userId, 'email' => $email],
]);
