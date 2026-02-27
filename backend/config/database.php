<?php

declare(strict_types=1);

function getDbConnection(): PDO
{
    static $pdo = null;

    if ($pdo === null) {
        // Load local credentials if the file exists (never committed to git).
        // See config/local.php.example for the format.
        $localConfig = __DIR__ . '/local.php';
        if (file_exists($localConfig)) {
            require_once $localConfig;
        }

        $host = (string) getenv('DB_HOST') ?: '';
        $db   = (string) getenv('DB_NAME') ?: '';
        $user = (string) getenv('DB_USER') ?: '';
        $pass = (string) getenv('DB_PASS') ?: '';

        if ($host === '' || $db === '' || $user === '') {
            http_response_code(500);
            echo json_encode(['error' => 'Server configuration error']);
            exit;
        }

        $dsn  = "mysql:host=$host;dbname=$db;charset=utf8mb4";

        $pdo = new PDO($dsn, $user, $pass, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    }

    return $pdo;
}
