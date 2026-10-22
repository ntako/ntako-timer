<?php

declare(strict_types=1);

/**
 * Writes a user's categories, tasks and sessions with the sync rules. Shared
 * by the sync API (api/sync/push.php) and the admin panel import.
 *
 * - Every row that actually changes gets the next value of a per-user
 *   counter (users.sync_seq), which incremental pull uses as its cursor.
 * - Categories and tasks: last-write-wins on updated_at.
 * - Sessions: an end time is never lost, the longest duration wins.
 * - Timestamps before 2000 (devices without NTP) become server time.
 *
 * Use inside a transaction: the constructor locks the user row, which also
 * serialises concurrent writers so versions commit in increasing order and
 * a pull can never skip a row that committed late. Call finish() before
 * committing.
 */
final class SyncWriter
{
    private const MIN_VALID_MS = 946_684_800_000; // 2000-01-01

    public readonly int $nowMs;

    private int $seq;

    /** @var array<string,array<string,?int>> table → client_id → server id */
    private array $serverIds = ['categories' => [], 'tasks' => []];

    /** @var array<string,array{added:int,updated:int,unchanged:int}> */
    public array $counts = [
        'categories' => ['added' => 0, 'updated' => 0, 'unchanged' => 0],
        'tasks'      => ['added' => 0, 'updated' => 0, 'unchanged' => 0],
        'sessions'   => ['added' => 0, 'updated' => 0, 'unchanged' => 0],
    ];

    public function __construct(private readonly PDO $pdo, private readonly int $userId)
    {
        $this->nowMs = (int) (microtime(true) * 1000);

        $stmt = $pdo->prepare('SELECT sync_seq FROM users WHERE id = ? FOR UPDATE');
        $stmt->execute([$userId]);
        $this->seq = (int) $stmt->fetchColumn();
    }

    /** Stores the counter. Call once, right before committing. */
    public function finish(): void
    {
        $this->pdo->prepare('UPDATE users SET sync_seq = ? WHERE id = ?')
            ->execute([$this->seq, $this->userId]);
    }

    /**
     * @param list<array<string,mixed>> $categories rows in push format
     * @return list<array{client_id:string,server_id:int}>
     */
    public function upsertCategories(array $categories): array
    {
        $upsert = $this->pdo->prepare('
            INSERT INTO categories
                (user_id, client_id, name, color, created_at, updated_at, deleted_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                name       = IF(VALUES(updated_at) > updated_at, VALUES(name),       name),
                color      = IF(VALUES(updated_at) > updated_at, VALUES(color),      color),
                deleted_at = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at), deleted_at),
                version    = IF(VALUES(updated_at) > updated_at, VALUES(version),    version),
                updated_at = IF(VALUES(updated_at) > updated_at, VALUES(updated_at), updated_at)
        ');

        $synced = [];
        foreach ($categories as $cat) {
            $clientId = (string) ($cat['client_id'] ?? '');
            if ($clientId === '') {
                continue;
            }
            $upsert->execute([
                $this->userId,
                $clientId,
                (string) ($cat['name']  ?? ''),
                (string) ($cat['color'] ?? '#6366f1'),
                $this->validTs((int) ($cat['created_at'] ?? 0)),
                $this->validTs((int) ($cat['updated_at'] ?? 0)),
                isset($cat['deleted_at']) ? $this->validTs((int) $cat['deleted_at']) : null,
                ++$this->seq,
            ]);
            $this->count('categories', $upsert->rowCount());
            $synced[] = $this->synced('categories', $clientId);
        }
        return array_values(array_filter($synced));
    }

    /**
     * A push without `title` or `description` keeps the stored value instead
     * of blanking it: clients that don't hold those fields (the Cardputer has
     * no description and a 63-character title) must not erase them. Sending
     * the key with null still clears the description.
     *
     * @param list<array<string,mixed>> $tasks rows in push format
     * @return list<array{client_id:string,server_id:int}>
     */
    public function upsertTasks(array $tasks): array
    {
        $upsert = $this->pdo->prepare('
            INSERT INTO tasks
                (user_id, client_id, category_id, title, description, type,
                 is_completed, created_at, updated_at, deleted_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                category_id  = IF(VALUES(updated_at) > updated_at, VALUES(category_id),  category_id),
                title        = IF(VALUES(updated_at) > updated_at AND ? = 1, VALUES(title),       title),
                description  = IF(VALUES(updated_at) > updated_at AND ? = 1, VALUES(description), description),
                is_completed = IF(VALUES(updated_at) > updated_at, VALUES(is_completed), is_completed),
                deleted_at   = IF(VALUES(updated_at) > updated_at, VALUES(deleted_at),   deleted_at),
                version      = IF(VALUES(updated_at) > updated_at, VALUES(version),      version),
                updated_at   = IF(VALUES(updated_at) > updated_at, VALUES(updated_at),   updated_at)
        ');

        $synced = [];
        foreach ($tasks as $task) {
            $clientId = (string) ($task['client_id'] ?? '');
            if ($clientId === '') {
                continue;
            }
            $upsert->execute([
                $this->userId,
                $clientId,
                $this->serverId('categories', (string) ($task['category_client_id'] ?? '')),
                (string) ($task['title'] ?? ''),
                isset($task['description']) ? (string) $task['description'] : null,
                'tracker',
                (int) ($task['is_completed'] ?? 0),
                $this->validTs((int) ($task['created_at'] ?? 0)),
                $this->validTs((int) ($task['updated_at'] ?? 0)),
                isset($task['deleted_at']) ? $this->validTs((int) $task['deleted_at']) : null,
                ++$this->seq,
                (int) array_key_exists('title', $task),
                (int) array_key_exists('description', $task),
            ]);
            $this->count('tasks', $upsert->rowCount());
            $synced[] = $this->synced('tasks', $clientId);
        }
        return array_values(array_filter($synced));
    }

    /**
     * @param list<array<string,mixed>> $sessions rows in push format
     * @return list<array{client_id:string,server_id:int}>
     */
    public function upsertSessions(array $sessions): array
    {
        // `version` is assigned first, while the other columns still hold
        // their old values: it only moves when the merge changes something.
        $upsert = $this->pdo->prepare('
            INSERT INTO sessions
                (user_id, task_id, client_id, type, started_at, ended_at,
                 duration_seconds, is_completed, created_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                version          = IF((ended_at IS NULL AND VALUES(ended_at) IS NOT NULL)
                                      OR VALUES(duration_seconds) > duration_seconds
                                      OR (is_completed = 0 AND VALUES(is_completed) = 1),
                                      VALUES(version), version),
                ended_at         = COALESCE(ended_at, VALUES(ended_at)),
                duration_seconds = GREATEST(duration_seconds, VALUES(duration_seconds)),
                is_completed     = IF(is_completed = 0, VALUES(is_completed), is_completed),
                created_at       = IF(created_at = 0, VALUES(created_at), created_at)
        ');
        $getId = $this->pdo->prepare('SELECT id FROM sessions WHERE user_id = ? AND client_id = ?');

        $synced = [];
        foreach ($sessions as $session) {
            $clientId = (string) ($session['client_id'] ?? '');
            if ($clientId === '') {
                continue;
            }

            $startedAt   = (int) ($session['started_at'] ?? 0);
            $endedAt     = isset($session['ended_at']) ? (int) $session['ended_at'] : null;
            $durationSec = (int) ($session['duration_seconds'] ?? 0);

            // Offline sessions have no NTP: started_at will be near epoch 0.
            // Reconstruct timestamps from server time so history is usable.
            if ($startedAt < self::MIN_VALID_MS) {
                $endedAt   = $this->nowMs;
                $startedAt = $this->nowMs - $durationSec * 1000;
            }

            $upsert->execute([
                $this->userId,
                $this->serverId('tasks', (string) ($session['task_client_id'] ?? '')),
                $clientId,
                'tracking',
                $startedAt,
                $endedAt,
                $durationSec,
                (int) ($session['is_completed'] ?? 0),
                $this->nowMs, // server time: legacy pull (created_at > since) finds it
                ++$this->seq,
            ]);
            $this->count('sessions', $upsert->rowCount());

            $getId->execute([$this->userId, $clientId]);
            $id = $getId->fetchColumn();
            if ($id !== false) {
                $synced[] = ['client_id' => $clientId, 'server_id' => (int) $id];
            }
        }
        return $synced;
    }

    /**
     * Closes this user's open sessions matching $where (appended to
     * "user_id = ? AND ended_at IS NULL AND"). Closing is a change other
     * devices must see, so each closed row gets its own version.
     *
     * @param list<mixed> $params values for the placeholders in $where
     */
    public function closeOpenSessions(string $where, array $params): void
    {
        $find = $this->pdo->prepare(
            "SELECT id FROM sessions WHERE user_id = ? AND ended_at IS NULL AND $where"
        );
        $find->execute([$this->userId, ...$params]);
        $close = $this->pdo->prepare(
            'UPDATE sessions SET ended_at = ?, is_completed = 0, version = ? WHERE id = ?'
        );
        foreach ($find->fetchAll(PDO::FETCH_COLUMN) as $id) {
            $close->execute([$this->nowMs, ++$this->seq, (int) $id]);
        }
    }

    private function validTs(int $ms): int
    {
        return $ms < self::MIN_VALID_MS ? $this->nowMs : $ms;
    }

    /** Server id for a client id in $table, null if unknown (or empty). */
    private function serverId(string $table, string $clientId): ?int
    {
        if ($clientId === '') {
            return null;
        }
        if (!array_key_exists($clientId, $this->serverIds[$table])) {
            $stmt = $this->pdo->prepare("SELECT id FROM $table WHERE user_id = ? AND client_id = ?");
            $stmt->execute([$this->userId, $clientId]);
            $id = $stmt->fetchColumn();
            $this->serverIds[$table][$clientId] = $id === false ? null : (int) $id;
        }
        return $this->serverIds[$table][$clientId];
    }

    /** @return array{client_id:string,server_id:int}|null */
    private function synced(string $table, string $clientId): ?array
    {
        unset($this->serverIds[$table][$clientId]); // just written: look it up again
        $id = $this->serverId($table, $clientId);
        return $id === null ? null : ['client_id' => $clientId, 'server_id' => $id];
    }

    /** MySQL affected rows for INSERT … ON DUPLICATE KEY UPDATE: 1 new, 2 changed, 0 same. */
    private function count(string $table, int $affected): void
    {
        $key = match ($affected) {
            1       => 'added',
            0       => 'unchanged',
            default => 'updated',
        };
        $this->counts[$table][$key]++;
    }
}
