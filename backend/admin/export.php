<?php

declare(strict_types=1);

/**
 * Per-user data export for the admin panel.
 *
 * Both formats match the Flutter app's (lib/features/backup/backup_service.dart):
 * the JSON can be imported in the app as a backup, the CSV has the same
 * columns as the app's session export.
 */

/** @return array<string,mixed> */
function exportBackup(PDO $pdo, int $userId): array
{
    $stmt = $pdo->prepare('
        SELECT client_id, name, color, created_at, updated_at, deleted_at
        FROM categories WHERE user_id = ? ORDER BY id
    ');
    $stmt->execute([$userId]);
    $categories = array_map(static fn (array $c): array => [
        'id'         => $c['client_id'],
        'name'       => $c['name'],
        'color'      => $c['color'],
        'created_at' => (int) $c['created_at'],
        'updated_at' => (int) $c['updated_at'],
        'deleted_at' => $c['deleted_at'] !== null ? (int) $c['deleted_at'] : null,
    ], $stmt->fetchAll());

    $stmt = $pdo->prepare('
        SELECT t.client_id, c.client_id AS category_client_id, t.title,
               t.description, t.is_completed, t.created_at, t.updated_at,
               t.deleted_at
        FROM tasks t
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE t.user_id = ? ORDER BY t.id
    ');
    $stmt->execute([$userId]);
    $tasks = array_map(static fn (array $t): array => [
        'id'           => $t['client_id'],
        'category_id'  => $t['category_client_id'],
        'title'        => $t['title'],
        'description'  => $t['description'],
        'is_completed' => (bool) $t['is_completed'],
        'created_at'   => (int) $t['created_at'],
        'updated_at'   => (int) $t['updated_at'],
        'deleted_at'   => $t['deleted_at'] !== null ? (int) $t['deleted_at'] : null,
    ], $stmt->fetchAll());

    $stmt = $pdo->prepare('
        SELECT s.client_id, t.client_id AS task_client_id, s.type,
               s.started_at, s.ended_at, s.duration_seconds, s.is_completed,
               s.created_at
        FROM sessions s
        LEFT JOIN tasks t ON t.id = s.task_id
        WHERE s.user_id = ? ORDER BY s.id
    ');
    $stmt->execute([$userId]);
    $sessions = array_map(static fn (array $s): array => [
        'id'               => $s['client_id'],
        'task_id'          => $s['task_client_id'],
        'type'             => $s['type'],
        'started_at'       => (int) $s['started_at'],
        'ended_at'         => $s['ended_at'] !== null ? (int) $s['ended_at'] : null,
        'duration_seconds' => (int) $s['duration_seconds'],
        'is_completed'     => (bool) $s['is_completed'],
        'created_at'       => (int) $s['created_at'],
    ], $stmt->fetchAll());

    return [
        'format'      => 'ntako-timer-backup',
        'version'     => 1,
        'exported_at' => (int) (microtime(true) * 1000),
        'categories'  => $categories,
        'tasks'       => $tasks,
        'sessions'    => $sessions,
    ];
}

/**
 * Finished sessions, oldest first. Semicolon-separated with a UTF-8 BOM so
 * Excel with an Italian locale opens it directly. Times use the server's
 * timezone, like the rest of the admin panel.
 */
function exportSessionsCsv(PDO $pdo, int $userId): string
{
    $stmt = $pdo->prepare('
        SELECT s.started_at, s.ended_at, s.duration_seconds,
               t.title AS task_title, c.name AS category_name
        FROM sessions s
        LEFT JOIN tasks t      ON t.id = s.task_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE s.user_id = ? AND s.ended_at IS NOT NULL
        ORDER BY s.started_at
    ');
    $stmt->execute([$userId]);

    $row = static function (array $fields): string {
        return implode(';', array_map(static function ($f): string {
            $f = (string) $f;
            return preg_match('/[;"\r\n]/', $f)
                ? '"' . str_replace('"', '""', $f) . '"'
                : $f;
        }, $fields)) . "\r\n";
    };

    $csv = "\u{FEFF}" . $row(['Data', 'Inizio', 'Fine', 'Durata', 'Minuti', 'Task', 'Categoria']);
    foreach ($stmt->fetchAll() as $s) {
        $start = intdiv((int) $s['started_at'], 1000);
        $end   = intdiv((int) $s['ended_at'], 1000);
        $d     = (int) $s['duration_seconds'];
        $csv  .= $row([
            date('d/m/Y', $start),
            date('H:i', $start),
            date('H:i', $end),
            sprintf('%d:%02d:%02d', intdiv($d, 3600), intdiv($d % 3600, 60), $d % 60),
            (int) round($d / 60),
            $s['task_title'] ?? '',
            $s['category_name'] ?? '',
        ]);
    }
    return $csv;
}
