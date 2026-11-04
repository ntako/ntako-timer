<?php

declare(strict_types=1);

/**
 * Presence detection ("badge"): devices detect when they are in a known
 * place, by GPS position and/or Wi-Fi network, and record each stay.
 * Shared by the API (api/presence/*) and the admin panel.
 *
 * Policy, set for the platform and optionally overridden per user:
 * - off:   no detection.
 * - admin: the admin sets the mode and the places; devices only detect.
 * - user:  each device picks its mode, the user manages their own places.
 * Platform places (user_id NULL) are seen by every user and edited only by
 * the admin, whatever the policy.
 */
final class Presence
{
    public const POLICIES = [
        'off'   => 'Disattivato',
        'admin' => "Gestito dall'amministratore",
        'user'  => "Gestito dall'utente",
    ];

    public const MODES = [
        'gps'          => 'Solo GPS',
        'wifi'         => 'Solo Wi-Fi',
        'gps_and_wifi' => 'GPS e Wi-Fi (entrambi)',
        'gps_or_wifi'  => 'GPS o Wi-Fi (almeno uno)',
    ];

    public const DEFAULT_POLICY = 'off';
    public const DEFAULT_MODE   = 'gps_or_wifi';

    public const MIN_RADIUS = 10;
    public const MAX_RADIUS = 5000;
    private const MAX_WIFI  = 20;

    /** A stay still open whose device has been silent this long is treated as ended at last_seen_at. */
    public const STALE_MS = 30 * 60 * 1000;

    private const BSSID_RE = '/^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/i';

    // ── Settings ─────────────────────────────────────────────────────────────

    /** @return array{policy:string,mode:string} */
    public static function platformSettings(PDO $pdo): array
    {
        $rows = $pdo->query(
            "SELECT name, value FROM app_settings WHERE name IN ('presence_policy', 'presence_mode')"
        )->fetchAll(PDO::FETCH_KEY_PAIR);
        return [
            'policy' => self::policyOr($rows['presence_policy'] ?? null, self::DEFAULT_POLICY),
            'mode'   => self::modeOr($rows['presence_mode'] ?? null, self::DEFAULT_MODE),
        ];
    }

    public static function savePlatformSettings(PDO $pdo, string $policy, string $mode): void
    {
        $stmt = $pdo->prepare(
            'INSERT INTO app_settings (name, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)'
        );
        $stmt->execute(['presence_policy', self::policyOr($policy, self::DEFAULT_POLICY)]);
        $stmt->execute(['presence_mode', self::modeOr($mode, self::DEFAULT_MODE)]);
    }

    /** @return array{policy:?string,mode:?string} null = inherited from the platform */
    public static function userOverride(PDO $pdo, int $userId): array
    {
        $stmt = $pdo->prepare('SELECT policy, mode FROM user_presence WHERE user_id = ?');
        $stmt->execute([$userId]);
        $row = $stmt->fetch() ?: [];
        return [
            'policy' => self::policyOr($row['policy'] ?? null, null),
            'mode'   => self::modeOr($row['mode'] ?? null, null),
        ];
    }

    /** Empty or unknown values mean "inherit". */
    public static function saveUserOverride(PDO $pdo, int $userId, ?string $policy, ?string $mode): void
    {
        $policy = self::policyOr($policy, null);
        $mode   = self::modeOr($mode, null);
        if ($policy === null && $mode === null) {
            $pdo->prepare('DELETE FROM user_presence WHERE user_id = ?')->execute([$userId]);
            return;
        }
        $pdo->prepare('
            INSERT INTO user_presence (user_id, policy, mode) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE policy = VALUES(policy), mode = VALUES(mode)
        ')->execute([$userId, $policy, $mode]);
    }

    /** @return array{policy:string,mode:string} what applies to this user */
    public static function effectiveSettings(PDO $pdo, int $userId): array
    {
        $platform = self::platformSettings($pdo);
        $override = self::userOverride($pdo, $userId);
        return [
            'policy' => $override['policy'] ?? $platform['policy'],
            'mode'   => $override['mode']   ?? $platform['mode'],
        ];
    }

    // ── Places ───────────────────────────────────────────────────────────────

    /**
     * Places a user's devices detect: the platform's and the user's own.
     *
     * @return list<array<string,mixed>> API format
     */
    public static function placesFor(PDO $pdo, int $userId, bool $userCanEdit): array
    {
        $stmt = $pdo->prepare('
            SELECT id, user_id, client_id, name, latitude, longitude, radius_m, wifi, updated_at
            FROM places
            WHERE (user_id IS NULL OR user_id = ?) AND deleted_at IS NULL
            ORDER BY user_id IS NOT NULL, name
        ');
        $stmt->execute([$userId]);
        $slots = self::placeSlots($pdo, $userId);
        return array_map(static fn (array $p): array => [
            'client_id'  => (string) $p['client_id'],
            'slot'       => $slots[(int) $p['id']] ?? 0,
            'name'       => (string) $p['name'],
            'latitude'   => $p['latitude']  !== null ? (float) $p['latitude']  : null,
            'longitude'  => $p['longitude'] !== null ? (float) $p['longitude'] : null,
            'radius_m'   => (int) $p['radius_m'],
            'wifi'       => self::decodeWifi($p['wifi']),
            'scope'      => $p['user_id'] === null ? 'platform' : 'user',
            'editable'   => $userCanEdit && $p['user_id'] !== null,
            'updated_at' => (int) $p['updated_at'],
        ], $stmt->fetchAll());
    }

    /**
     * Admin listing: platform places ($userId null) or a user's own.
     *
     * @return list<array<string,mixed>>
     */
    public static function adminPlaces(PDO $pdo, ?int $userId): array
    {
        $stmt = $userId === null
            ? $pdo->prepare('SELECT * FROM places WHERE user_id IS NULL AND deleted_at IS NULL ORDER BY name')
            : $pdo->prepare('SELECT * FROM places WHERE user_id = ? AND deleted_at IS NULL ORDER BY name');
        $stmt->execute($userId === null ? [] : [$userId]);
        return array_map(static function (array $p): array {
            $p['wifi'] = self::decodeWifi($p['wifi']);
            return $p;
        }, $stmt->fetchAll());
    }

    /**
     * Validates and normalises place fields (name, latitude, longitude,
     * radius_m, wifi). A place needs a position, a Wi-Fi network or both.
     *
     * @param array<string,mixed> $in
     * @return array{name:string,latitude:?float,longitude:?float,radius_m:int,wifi:list<string>}
     * @throws InvalidArgumentException with a message for the user
     */
    public static function validatePlace(array $in): array
    {
        $name = trim((string) ($in['name'] ?? ''));
        if ($name === '' || mb_strlen($name) > 100) {
            throw new InvalidArgumentException('Il nome del luogo è obbligatorio (max 100 caratteri).');
        }

        $num = static fn ($v): ?float =>
            $v === null || $v === '' ? null : (is_numeric($v) ? (float) $v : NAN);
        $lat = $num($in['latitude'] ?? null);
        $lon = $num($in['longitude'] ?? null);
        if (($lat === null) !== ($lon === null)) {
            throw new InvalidArgumentException('Indica sia la latitudine sia la longitudine, o nessuna delle due.');
        }
        if ($lat !== null && (is_nan($lat) || is_nan($lon) || abs($lat) > 90 || abs($lon) > 180)) {
            throw new InvalidArgumentException('Coordinate non valide.');
        }

        $radius = (int) ($in['radius_m'] ?? 100);
        if ($radius < self::MIN_RADIUS || $radius > self::MAX_RADIUS) {
            throw new InvalidArgumentException(
                sprintf('Il raggio deve essere tra %d e %d metri.', self::MIN_RADIUS, self::MAX_RADIUS)
            );
        }

        $wifi = self::normalizeWifi($in['wifi'] ?? []);
        if ($lat === null && $wifi === []) {
            throw new InvalidArgumentException('Indica una posizione, almeno una rete Wi-Fi, o entrambe.');
        }

        return ['name' => $name, 'latitude' => $lat, 'longitude' => $lon, 'radius_m' => $radius, 'wifi' => $wifi];
    }

    /**
     * Wi-Fi networks from a list or from text (one per line). An entry that
     * looks like a MAC address is a BSSID (one access point), anything else
     * an SSID (network name, every access point of it).
     *
     * @param mixed $wifi
     * @return list<string>
     */
    public static function normalizeWifi(mixed $wifi): array
    {
        $items = is_array($wifi) ? $wifi : preg_split('/\R/', (string) $wifi);
        $out   = [];
        foreach ($items as $item) {
            $item = trim((string) $item);
            if ($item === '' || mb_strlen($item) > 64) {
                continue;
            }
            if (preg_match(self::BSSID_RE, $item)) {
                $item = strtolower(str_replace('-', ':', $item));
            }
            $out[$item] = true;
        }
        if (count($out) > self::MAX_WIFI) {
            throw new InvalidArgumentException(sprintf('Al massimo %d reti Wi-Fi per luogo.', self::MAX_WIFI));
        }
        return array_keys($out);
    }

    /**
     * Admin create/update. $userId null = platform place. $clientId null
     * creates a new place.
     *
     * @param array<string,mixed> $in raw fields, validated here
     * @throws InvalidArgumentException
     */
    public static function adminSavePlace(PDO $pdo, ?int $userId, ?string $clientId, array $in): void
    {
        $p   = self::validatePlace($in);
        $now = self::nowMs();
        if ($clientId === null) {
            $pdo->prepare('
                INSERT INTO places (user_id, client_id, name, latitude, longitude, radius_m, wifi, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ')->execute([$userId, self::uuid(), $p['name'], $p['latitude'], $p['longitude'],
                         $p['radius_m'], json_encode($p['wifi']), $now, $now]);
            return;
        }
        $stmt = $pdo->prepare('
            UPDATE places SET name = ?, latitude = ?, longitude = ?, radius_m = ?, wifi = ?, updated_at = ?
            WHERE client_id = ? AND ' . ($userId === null ? 'user_id IS NULL' : 'user_id = ?')
        );
        $stmt->execute([$p['name'], $p['latitude'], $p['longitude'], $p['radius_m'],
                        json_encode($p['wifi']), $now, $clientId, ...($userId === null ? [] : [$userId])]);
    }

    public static function adminDeletePlace(PDO $pdo, ?int $userId, string $clientId): void
    {
        $now = self::nowMs();
        $pdo->prepare(
            'UPDATE places SET deleted_at = ?, updated_at = ? WHERE client_id = ? AND '
            . ($userId === null ? 'user_id IS NULL' : 'user_id = ?')
        )->execute([$now, $now, $clientId, ...($userId === null ? [] : [$userId])]);
    }

    /**
     * Places created, edited or deleted on a device (policy "user").
     * Last write wins on updated_at; rows of other users or of the platform
     * are never touched.
     *
     * @param list<array<string,mixed>> $places
     * @return list<string> client ids stored (or already newer on the server)
     * @throws InvalidArgumentException
     */
    public static function upsertUserPlaces(PDO $pdo, int $userId, array $places): array
    {
        $find = $pdo->prepare('SELECT user_id, updated_at FROM places WHERE client_id = ?');
        $insert = $pdo->prepare('
            INSERT INTO places (user_id, client_id, name, latitude, longitude, radius_m, wifi,
                                created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ');
        $update = $pdo->prepare('
            UPDATE places SET name = ?, latitude = ?, longitude = ?, radius_m = ?, wifi = ?,
                              updated_at = ?, deleted_at = ?
            WHERE client_id = ? AND user_id = ?
        ');

        $now    = self::nowMs();
        $stored = [];
        foreach ($places as $in) {
            $clientId = (string) ($in['client_id'] ?? '');
            if (!self::isUuid($clientId)) {
                throw new InvalidArgumentException('Invalid place id');
            }
            $updatedAt = (int) ($in['updated_at'] ?? 0) ?: $now;
            $deletedAt = isset($in['deleted_at']) ? (int) $in['deleted_at'] : null;
            // A deletion needs no valid fields: keep the stored ones.
            $p = $deletedAt === null ? self::validatePlace($in) : null;

            $find->execute([$clientId]);
            $current = $find->fetch();
            if ($current === false) {
                if ($p === null) {
                    $stored[] = $clientId; // deleting something never stored
                    continue;
                }
                $insert->execute([$userId, $clientId, $p['name'], $p['latitude'], $p['longitude'],
                                  $p['radius_m'], json_encode($p['wifi']), $updatedAt, $updatedAt, null]);
            } elseif ((int) ($current['user_id'] ?? 0) !== $userId) {
                continue; // not this user's place
            } elseif ($updatedAt > (int) $current['updated_at']) {
                if ($p === null) {
                    $pdo->prepare('UPDATE places SET deleted_at = ?, updated_at = ? WHERE client_id = ? AND user_id = ?')
                        ->execute([$deletedAt, $updatedAt, $clientId, $userId]);
                } else {
                    $update->execute([$p['name'], $p['latitude'], $p['longitude'], $p['radius_m'],
                                      json_encode($p['wifi']), $updatedAt, null, $clientId, $userId]);
                }
            }
            $stored[] = $clientId;
        }
        return $stored;
    }

    /**
     * Color slot of each place a user can have stays in (theirs and the
     * platform's, deleted ones included): 1–8 in creation order, so a place
     * keeps its color whatever the report filters. Beyond eight places, 0
     * (neutral): a ninth color would no longer be told apart.
     *
     * @return array<int,int> place id → slot
     */
    public static function placeSlots(PDO $pdo, int $userId): array
    {
        $stmt = $pdo->prepare('SELECT id FROM places WHERE user_id IS NULL OR user_id = ? ORDER BY id');
        $stmt->execute([$userId]);
        $slots = [];
        foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $i => $id) {
            $slots[(int) $id] = $i < 8 ? $i + 1 : 0;
        }
        return $slots;
    }

    /**
     * The user's stays overlapping [$fromMs, $toMs), from every device,
     * oldest first. `place` is the place's client_id, or "n:<name>" when the
     * place is gone; `slot` its color slot.
     *
     * @return list<array<string,mixed>>
     */
    public static function stays(PDO $pdo, int $userId, int $fromMs, int $toMs): array
    {
        $stmt = $pdo->prepare('
            SELECT p.client_id, p.place_id, pl.client_id AS place_client_id,
                   COALESCE(pl.name, p.place_name) AS place_name,
                   p.device, p.method, p.entered_at, p.exited_at, p.last_seen_at
            FROM presences p
            LEFT JOIN places pl ON pl.id = p.place_id
            WHERE p.user_id = ? AND p.entered_at < ? AND COALESCE(p.exited_at, p.last_seen_at) >= ?
            ORDER BY p.entered_at
            LIMIT 10000
        ');
        $stmt->execute([$userId, $toMs, $fromMs]);
        $slots = self::placeSlots($pdo, $userId);
        return array_map(static fn (array $r): array => [
            'client_id'    => (string) $r['client_id'],
            'place'        => $r['place_client_id'] !== null ? (string) $r['place_client_id'] : 'n:' . $r['place_name'],
            'place_name'   => (string) $r['place_name'],
            'slot'         => $r['place_id'] !== null ? ($slots[(int) $r['place_id']] ?? 0) : 0,
            'device'       => (string) $r['device'],
            'method'       => (string) $r['method'],
            'entered_at'   => (int) $r['entered_at'],
            'exited_at'    => $r['exited_at'] !== null ? (int) $r['exited_at'] : null,
            'last_seen_at' => (int) $r['last_seen_at'],
        ], $stmt->fetchAll());
    }

    /** First day with a stay, server timezone; null without stays. */
    public static function firstStayMs(PDO $pdo, int $userId): ?int
    {
        $stmt = $pdo->prepare('SELECT MIN(entered_at) FROM presences WHERE user_id = ?');
        $stmt->execute([$userId]);
        $ms = $stmt->fetchColumn();
        return $ms ? (int) $ms : null;
    }

    // ── Stays ────────────────────────────────────────────────────────────────

    /**
     * Stays recorded by a device. Merge rules, so a stale copy never
     * overwrites a newer one: an exit time is never lost, last_seen_at only
     * moves forward.
     *
     * @param list<array<string,mixed>> $rows
     * @return list<array{client_id:string,server_id:int}>
     */
    public static function upsertPresences(PDO $pdo, int $userId, array $rows): array
    {
        $placeId = $pdo->prepare('SELECT id FROM places WHERE client_id = ? AND (user_id IS NULL OR user_id = ?)');
        $upsert  = $pdo->prepare('
            INSERT INTO presences
                (user_id, client_id, place_id, place_name, device, method,
                 entered_at, exited_at, last_seen_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                exited_at    = COALESCE(exited_at, VALUES(exited_at)),
                last_seen_at = GREATEST(last_seen_at, VALUES(last_seen_at))
        ');
        $getId = $pdo->prepare('SELECT id FROM presences WHERE user_id = ? AND client_id = ?');

        $now    = self::nowMs();
        $synced = [];
        foreach ($rows as $r) {
            $clientId  = (string) ($r['client_id'] ?? '');
            $enteredAt = (int) ($r['entered_at'] ?? 0);
            if (!self::isUuid($clientId) || $enteredAt <= 0) {
                throw new InvalidArgumentException('Invalid presence data');
            }
            $exitedAt = isset($r['exited_at']) ? (int) $r['exited_at'] : null;
            $lastSeen = max($enteredAt, (int) ($r['last_seen_at'] ?? $enteredAt), $exitedAt ?? 0);

            $placeId->execute([(string) ($r['place_client_id'] ?? ''), $userId]);
            $pid = $placeId->fetchColumn();

            $upsert->execute([
                $userId,
                $clientId,
                $pid === false ? null : (int) $pid,
                mb_substr((string) ($r['place_name'] ?? ''), 0, 100),
                mb_substr((string) ($r['device'] ?? ''), 0, 50),
                in_array($r['method'] ?? '', ['gps', 'wifi', 'gps+wifi'], true) ? $r['method'] : '',
                $enteredAt,
                $exitedAt,
                $lastSeen,
                $now,
            ]);
            $getId->execute([$userId, $clientId]);
            $synced[] = ['client_id' => $clientId, 'server_id' => (int) $getId->fetchColumn()];
        }
        return $synced;
    }

    /**
     * @param list<array{int,int,bool}> $iv [start, end, open]
     * @return list<array{int,int,bool}> sorted, non-overlapping
     */
    public static function mergeIntervals(array $iv): array
    {
        usort($iv, static fn ($a, $b) => $a[0] <=> $b[0]);
        $out = [];
        foreach ($iv as $i) {
            $last = count($out) - 1;
            if ($last >= 0 && $i[0] <= $out[$last][1]) {
                if ($i[1] >= $out[$last][1]) {
                    $out[$last][2] = $i[1] > $out[$last][1] ? $i[2] : ($out[$last][2] || $i[2]);
                    $out[$last][1] = $i[1];
                }
            } else {
                $out[] = $i;
            }
        }
        return $out;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    public static function isUuid(string $s): bool
    {
        return (bool) preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i', $s);
    }

    private static function uuid(): string
    {
        $b    = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
        $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
    }

    private static function nowMs(): int
    {
        return (int) (microtime(true) * 1000);
    }

    /** @return list<string> */
    private static function decodeWifi(?string $json): array
    {
        $list = json_decode((string) $json, true);
        return is_array($list) ? array_values(array_filter($list, 'is_string')) : [];
    }

    private static function policyOr(mixed $v, ?string $default): ?string
    {
        return is_string($v) && array_key_exists($v, self::POLICIES) ? $v : $default;
    }

    private static function modeOr(mixed $v, ?string $default): ?string
    {
        return is_string($v) && array_key_exists($v, self::MODES) ? $v : $default;
    }
}
