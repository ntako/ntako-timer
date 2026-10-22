<?php

declare(strict_types=1);

require_once __DIR__ . '/../lib/SyncWriter.php';

/** An invalid backup; the message is shown to the admin as is. */
final class BackupImportError extends RuntimeException
{
}

/**
 * Merges a JSON backup (format of the app and of export.php) into a user's
 * data, all or nothing, with the sync rules (see SyncWriter): nothing is
 * deleted, the user's devices receive the changes on their next sync.
 *
 * Validation mirrors the app's import (lib/features/backup/backup_service.dart).
 *
 * @return array<string,array{added:int,updated:int,unchanged:int}>
 * @throws BackupImportError
 */
function importBackup(PDO $pdo, int $userId, string $json): array
{
    $data = json_decode($json, true);
    if (!is_array($data)) {
        throw new BackupImportError('Il file non è un JSON valido.');
    }
    if (($data['format'] ?? null) !== 'ntako-timer-backup') {
        throw new BackupImportError('Il file non è un backup di NTAKO Timer.');
    }
    if (!is_int($data['version'] ?? null) || $data['version'] > 1) {
        throw new BackupImportError('Versione del backup non supportata.');
    }

    $rows = static function (string $key) use ($data): array {
        $list = $data[$key] ?? [];
        if (!is_array($list) || !array_is_list($list)) {
            throw new BackupImportError("Backup non valido: campo \"$key\" errato.");
        }
        foreach ($list as $i => $row) {
            if (!is_array($row)) {
                throw new BackupImportError("Backup non valido: campo \"{$key}[$i]\" errato.");
            }
        }
        return $list;
    };

    $categories = [];
    foreach ($rows('categories') as $i => $c) {
        $f = new BackupFields($c, "categories[$i]");
        $categories[] = [
            'client_id'  => $f->uuid('id'),
            'name'       => $f->string('name', 100),
            'color'      => $f->color('color'),
            'created_at' => $f->timestamp('created_at'),
            'updated_at' => $f->timestamp('updated_at'),
            'deleted_at' => $f->optionalTimestamp('deleted_at'),
        ];
    }

    $tasks = [];
    foreach ($rows('tasks') as $i => $t) {
        $f = new BackupFields($t, "tasks[$i]");
        $tasks[] = [
            'client_id'          => $f->uuid('id'),
            'category_client_id' => $f->optionalUuid('category_id'),
            'title'              => $f->string('title', 255, allowEmpty: true),
            'description'        => $f->optionalString('description'),
            'is_completed'       => (int) $f->boolean('is_completed'),
            'created_at'         => $f->timestamp('created_at'),
            'updated_at'         => $f->timestamp('updated_at'),
            'deleted_at'         => $f->optionalTimestamp('deleted_at'),
        ];
    }

    $sessions = [];
    foreach ($rows('sessions') as $i => $s) {
        $f = new BackupFields($s, "sessions[$i]");
        $sessions[] = [
            'client_id'        => $f->uuid('id'),
            'task_client_id'   => $f->optionalUuid('task_id'),
            'type'             => $f->string('type', 20),
            'started_at'       => $f->timestamp('started_at'),
            'ended_at'         => $f->optionalTimestamp('ended_at'),
            'duration_seconds' => $f->duration('duration_seconds'),
            'is_completed'     => (int) $f->boolean('is_completed'),
        ];
    }

    $pdo->beginTransaction();
    try {
        $writer = new SyncWriter($pdo, $userId);
        // References to rows missing from both the file and the database
        // end up as NULL (uncategorised task, session without task).
        $writer->upsertCategories($categories);
        $writer->upsertTasks($tasks);
        $writer->upsertSessions($sessions);
        $writer->finish();
        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }
    return $writer->counts;
}

/** Typed access to one backup row; throws on the first invalid field. */
final class BackupFields
{
    private const UUID = '/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i';

    /** @param array<string,mixed> $row */
    public function __construct(private readonly array $row, private readonly string $where)
    {
    }

    public function uuid(string $key): string
    {
        $v = $this->row[$key] ?? null;
        return is_string($v) && preg_match(self::UUID, $v) ? $v : $this->fail($key);
    }

    public function optionalUuid(string $key): ?string
    {
        return ($this->row[$key] ?? null) === null ? null : $this->uuid($key);
    }

    public function string(string $key, int $maxLength, bool $allowEmpty = false): string
    {
        $v = $this->row[$key] ?? null;
        return is_string($v) && ($allowEmpty || $v !== '') && mb_strlen($v) <= $maxLength
            ? $v : $this->fail($key);
    }

    public function optionalString(string $key): ?string
    {
        $v = $this->row[$key] ?? null;
        return $v === null || is_string($v) ? $v : $this->fail($key);
    }

    public function color(string $key): string
    {
        $v = $this->row[$key] ?? null;
        return is_string($v) && preg_match('/^#[0-9a-f]{6}$/i', $v) ? $v : $this->fail($key);
    }

    public function boolean(string $key): bool
    {
        $v = $this->row[$key] ?? null;
        return is_bool($v) ? $v : $this->fail($key);
    }

    public function timestamp(string $key): int
    {
        $v = $this->row[$key] ?? null;
        return is_int($v) && $v >= 0 ? $v : $this->fail($key);
    }

    public function optionalTimestamp(string $key): ?int
    {
        return ($this->row[$key] ?? null) === null ? null : $this->timestamp($key);
    }

    /** Seconds, within MySQL INT like sessions.duration_seconds. */
    public function duration(string $key): int
    {
        $v = $this->row[$key] ?? null;
        return is_int($v) && $v >= 0 && $v <= 2_147_483_647 ? $v : $this->fail($key);
    }

    private function fail(string $key): never
    {
        throw new BackupImportError(
            "Backup non valido: campo \"{$this->where}.$key\" mancante o errato."
        );
    }
}
