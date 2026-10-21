<?php

declare(strict_types=1);

// Load local credentials if the file exists (never committed to git).
// See config/local.php.example for the format. This must run as soon as this
// file is included, not lazily: JWT_SECRET and ADMIN_PASS are read before
// any database connection is opened.
if (file_exists(__DIR__ . '/local.php')) {
    require_once __DIR__ . '/local.php';
}

/**
 * Read a secret from the environment, or null if it is missing or still one
 * of the placeholders from the example files. Callers must refuse to work
 * without it: a publicly known secret is no better than none.
 */
function configuredSecret(string $name): ?string
{
    $placeholders = [
        'change_me_to_a_random_64_char_string_before_production', // .env.example
        'change_this_to_a_long_random_string',                    // local.php.example
        'change_this_admin_password',                             // local.php.example
    ];

    $value = (string) getenv($name);
    return $value === '' || in_array($value, $placeholders, true) ? null : $value;
}

function getDbConnection(): PDO
{
    static $pdo = null;

    if ($pdo === null) {
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

        try {
            $pdo = new PDO($dsn, $user, $pass, [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
            ]);
        } catch (PDOException $e) {
            // The message can include host and user name: log it, don't show it.
            error_log('Database connection failed: ' . $e->getMessage());
            http_response_code(500);
            echo json_encode(['error' => 'Server configuration error']);
            exit;
        }
    }

    return $pdo;
}
