<?php

declare(strict_types=1);

/**
 * Simple file-based sliding-window rate limiter.
 *
 * Uses the system temp directory so no database or APCu is required —
 * works on any shared PHP hosting.  Race conditions are minimised with
 * LOCK_EX but are acceptable for a personal-use application.
 *
 * Usage:
 *   if (!RateLimit::check('auth_login', 10, 600)) {
 *       RateLimit::tooManyRequests();
 *   }
 */
class RateLimit
{
    /**
     * Check and record a hit for the current client IP + action.
     *
     * @param string $action   Unique identifier for the endpoint.
     * @param int    $maxHits  Maximum number of requests allowed in the window.
     * @param int    $window   Sliding-window duration in seconds.
     *
     * @return bool  true = request is allowed; false = limit exceeded.
     */
    public static function check(string $action, int $maxHits = 10, int $window = 600): bool
    {
        $ip   = self::clientIp();
        $hash = hash('sha256', $ip . '|' . $action);
        $dir  = dirname(__DIR__) . DIRECTORY_SEPARATOR . 'cache';
        if (!is_dir($dir)) {
            @mkdir($dir, 0700, true);
        }
        $file = $dir . DIRECTORY_SEPARATOR . 'rl_' . $hash;
        $now  = time();

        $fp = @fopen($file, 'c+');
        if ($fp === false) {
            // Cannot write (permissions issue) — allow the request rather than
            // blocking all traffic.
            return true;
        }

        $allowed = true;

        if (flock($fp, LOCK_EX)) {
            $raw  = (string) stream_get_contents($fp);
            $data = [];

            if ($raw !== '') {
                /** @var array{start?:int,hits?:int}|null $decoded */
                $decoded = json_decode($raw, true);
                if (is_array($decoded)) {
                    $data = $decoded;
                }
            }

            $start = (int) ($data['start'] ?? $now);
            $hits  = (int) ($data['hits']  ?? 0);

            // Reset the window if it has expired
            if ($now - $start >= $window) {
                $start = $now;
                $hits  = 0;
            }

            $hits++;

            if ($hits > $maxHits) {
                $allowed = false;
            } else {
                ftruncate($fp, 0);
                rewind($fp);
                fwrite($fp, (string) json_encode(['start' => $start, 'hits' => $hits]));
            }

            flock($fp, LOCK_UN);
        }

        fclose($fp);
        return $allowed;
    }

    /**
     * Send a 429 response and terminate execution.
     */
    public static function tooManyRequests(): never
    {
        http_response_code(429);
        header('Retry-After: 600');
        echo json_encode(['error' => 'Too many requests. Please try again in a few minutes.']);
        exit;
    }

    /**
     * Resolve the client IP.
     *
     * Only REMOTE_ADDR is used: X-Forwarded-For / X-Real-IP are set by the
     * client unless a trusted proxy overwrites them, so honouring them would
     * let anyone pick a fresh "IP" per request and bypass the limit.
     */
    private static function clientIp(): string
    {
        return (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
    }
}
