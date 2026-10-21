<?php

declare(strict_types=1);

/**
 * Minimal JWT implementation using HMAC-SHA256.
 * No Composer required — compatible with any shared PHP hosting.
 */
class Auth
{
    private static string $secret = '';

    /**
     * Load the signing secret. Exits with 500 if JWT_SECRET is not configured
     * (see configuredSecret() in config/database.php, which callers include
     * first) rather than signing tokens with a guessable fallback.
     */
    public static function init(): void
    {
        $secret = configuredSecret('JWT_SECRET');
        if ($secret === null) {
            http_response_code(500);
            echo json_encode(['error' => 'Server configuration error']);
            exit;
        }
        self::$secret = $secret;
    }

    /**
     * Create a signed JWT token.
     *
     * @param array<string,mixed> $payload
     */
    public static function encode(array $payload): string
    {
        $header  = self::base64url((string) json_encode(['alg' => 'HS256', 'typ' => 'JWT']));
        $payload = self::base64url((string) json_encode($payload));
        $sig     = self::base64url(
            hash_hmac('sha256', "$header.$payload", self::$secret, true)
        );

        return "$header.$payload.$sig";
    }

    /**
     * Verify and decode a JWT token.
     *
     * @return array<string,mixed>
     * @throws RuntimeException on invalid/expired token
     */
    public static function decode(string $token): array
    {
        $parts = explode('.', $token);
        if (count($parts) !== 3) {
            throw new RuntimeException('Invalid token format');
        }

        [$header, $payload, $sig] = $parts;

        $expectedSig = self::base64url(
            hash_hmac('sha256', "$header.$payload", self::$secret, true)
        );

        // Constant-time comparison to prevent timing attacks
        if (!hash_equals($expectedSig, $sig)) {
            throw new RuntimeException('Invalid token signature');
        }

        /** @var array<string,mixed>|null $data */
        $data = json_decode(self::base64urlDecode($payload), true);

        if (!is_array($data)) {
            throw new RuntimeException('Invalid token payload');
        }

        if (isset($data['exp']) && (int) $data['exp'] < time()) {
            throw new RuntimeException('Token expired');
        }

        return $data;
    }

    /**
     * Middleware: validate Bearer token from Authorization header.
     * Exits with 401 JSON response on failure.
     *
     * @return int Authenticated user ID
     */
    public static function requireAuth(): int
    {
        self::init();

        // Apache on shared hosting often strips Authorization — check multiple sources
        $authHeader = $_SERVER['HTTP_AUTHORIZATION']
                   ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION']
                   ?? (function_exists('apache_request_headers')
                       ? (apache_request_headers()['Authorization'] ?? '')
                       : '');

        if (!str_starts_with($authHeader, 'Bearer ')) {
            http_response_code(401);
            echo json_encode(['error' => 'Missing or malformed authorization token']);
            exit;
        }

        try {
            $payload = self::decode(substr($authHeader, 7));
            return (int) $payload['sub'];
        } catch (RuntimeException $e) {
            http_response_code(401);
            echo json_encode(['error' => $e->getMessage()]);
            exit;
        }
    }

    private static function base64url(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }

    private static function base64urlDecode(string $data): string
    {
        return (string) base64_decode(strtr($data, '-_', '+/'));
    }
}
