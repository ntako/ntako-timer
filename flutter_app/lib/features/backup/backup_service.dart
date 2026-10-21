import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../timer/timer_notifier.dart';

part 'backup_service.g.dart';

@riverpod
BackupService backupService(BackupServiceRef ref) =>
    BackupService(ref.watch(appDatabaseProvider));

/// Thrown when an imported file is not a valid backup. [message] is shown
/// to the user as is.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

class ImportCounts {
  int added = 0;
  int updated = 0;
  int unchanged = 0;
}

class ImportResult {
  final categories = ImportCounts();
  final tasks = ImportCounts();
  final sessions = ImportCounts();

  bool get changedAnything =>
      [categories, tasks, sessions].any((c) => c.added > 0 || c.updated > 0);
}

/// JSON backup / restore and CSV export of the local data.
///
/// The JSON format is shared with the admin panel export
/// (backend/admin/export.php): a file downloaded there can be imported here.
/// Rows are keyed by their client UUID and include soft-deleted ones, so a
/// restore also carries deletions.
class BackupService {
  static const format = 'ntako-timer-backup';
  static const formatVersion = 1;

  final AppDatabase db;

  BackupService(this.db);

  // ----------------------------------------------------------------
  // Export
  // ----------------------------------------------------------------

  Future<String> exportJson() async {
    final categories = await db.select(db.categories).get();
    final tasks = await db.select(db.tasks).get();
    final sessions = await db.select(db.sessions).get();

    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'version': formatVersion,
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'categories': [
        for (final c in categories)
          {
            'id': c.id,
            'name': c.name,
            'color': c.color,
            'created_at': c.createdAt,
            'updated_at': c.updatedAt,
            'deleted_at': c.deletedAt,
          },
      ],
      'tasks': [
        for (final t in tasks)
          {
            'id': t.id,
            'category_id': t.categoryId,
            'title': t.title,
            'description': t.description,
            'is_completed': t.isCompleted,
            'created_at': t.createdAt,
            'updated_at': t.updatedAt,
            'deleted_at': t.deletedAt,
          },
      ],
      'sessions': [
        for (final s in sessions)
          {
            'id': s.id,
            'task_id': s.taskId,
            'type': s.type,
            'started_at': s.startedAt,
            'ended_at': s.endedAt,
            'duration_seconds': s.durationSeconds,
            'is_completed': s.isCompleted,
            'created_at': s.createdAt,
          },
      ],
    });
  }

  /// Finished sessions, oldest first, for spreadsheets. Semicolon-separated
  /// with a UTF-8 BOM so Excel with an Italian locale opens it directly.
  /// Same columns as the admin panel CSV export.
  Future<String> exportSessionsCsv() async {
    final categories = {
      for (final c in await db.select(db.categories).get()) c.id: c,
    };
    final tasks = {for (final t in await db.select(db.tasks).get()) t.id: t};
    final sessions =
        await (db.select(db.sessions)
              ..where((s) => s.endedAt.isNotNull())
              ..orderBy([(s) => OrderingTerm.asc(s.startedAt)]))
            .get();

    final date = DateFormat('dd/MM/yyyy');
    final time = DateFormat('HH:mm');
    final buf = StringBuffer('﻿')
      ..write(
        _csvRow([
          'Data',
          'Inizio',
          'Fine',
          'Durata',
          'Minuti',
          'Task',
          'Categoria',
        ]),
      );

    for (final s in sessions) {
      final start = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      final end = DateTime.fromMillisecondsSinceEpoch(s.endedAt!);
      final task = tasks[s.taskId];
      final category = categories[task?.categoryId];
      final d = s.durationSeconds;
      buf.write(
        _csvRow([
          date.format(start),
          time.format(start),
          time.format(end),
          '${d ~/ 3600}:${_two(d % 3600 ~/ 60)}:${_two(d % 60)}',
          '${(d / 60).round()}',
          task?.title ?? '',
          category?.name ?? '',
        ]),
      );
    }
    return buf.toString();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _csvRow(List<String> fields) =>
      '${fields.map((f) {
        if (!f.contains(RegExp('[;"\r\n]'))) return f;
        return '"${f.replaceAll('"', '""')}"';
      }).join(';')}\r\n';

  // ----------------------------------------------------------------
  // Import
  // ----------------------------------------------------------------

  /// Merges a JSON backup into the local data, all or nothing.
  ///
  /// Nothing local is deleted. Categories and tasks follow the sync rule
  /// (the most recent `updated_at` wins); sessions are merged like the
  /// server does (an end time is never lost, the longest duration wins).
  /// Changed rows are marked unsynced so the next sync uploads them.
  Future<ImportResult> importJson(String source) async {
    final backup = _parse(source);
    final result = ImportResult();
    final activeSessionId = await db.settingsDao.getValue(
      activeSessionSettingsKey,
    );

    await db.transaction(() async {
      for (final c in backup.categories) {
        final local = await db.categoriesDao.getCategoryById(c.id.value);
        if (local == null) {
          await db.into(db.categories).insert(c);
          result.categories.added++;
        } else if (c.updatedAt.value > local.updatedAt) {
          await db.categoriesDao.updateCategory(c);
          result.categories.updated++;
        } else {
          result.categories.unchanged++;
        }
      }

      for (var t in backup.tasks) {
        // A category missing from both the file and this device would
        // violate the foreign key: keep the task, uncategorised.
        final categoryId = t.categoryId.value;
        if (categoryId != null &&
            await db.categoriesDao.getCategoryById(categoryId) == null) {
          t = t.copyWith(categoryId: const Value(null));
        }
        final local = await db.tasksDao.getTaskById(t.id.value);
        if (local == null) {
          await db.into(db.tasks).insert(t);
          result.tasks.added++;
        } else if (t.updatedAt.value > local.updatedAt) {
          await db.tasksDao.updateTask(t);
          result.tasks.updated++;
        } else {
          result.tasks.unchanged++;
        }
      }

      for (var s in backup.sessions) {
        final taskId = s.taskId.value;
        if (taskId != null && await db.tasksDao.getTaskById(taskId) == null) {
          s = s.copyWith(taskId: const Value(null));
        }
        final local = await db.sessionsDao.getSessionById(s.id.value);
        if (local == null) {
          await db.into(db.sessions).insert(s);
          result.sessions.added++;
          continue;
        }
        // The session being timed right now is owned by the timer.
        if (local.id == activeSessionId) {
          result.sessions.unchanged++;
          continue;
        }
        final endedAt = local.endedAt ?? s.endedAt.value;
        final duration = max(local.durationSeconds, s.durationSeconds.value);
        final isCompleted = local.isCompleted || s.isCompleted.value;
        if (endedAt == local.endedAt &&
            duration == local.durationSeconds &&
            isCompleted == local.isCompleted) {
          result.sessions.unchanged++;
          continue;
        }
        await (db.update(
          db.sessions,
        )..where((r) => r.id.equals(local.id))).write(
          SessionsCompanion(
            endedAt: Value(endedAt),
            durationSeconds: Value(duration),
            isCompleted: Value(isCompleted),
            isSynced: const Value(false),
          ),
        );
        result.sessions.updated++;
      }
    });

    return result;
  }

  static _Backup _parse(String source) {
    final Object? root;
    try {
      root = jsonDecode(source);
    } on FormatException {
      throw const BackupFormatException('Il file non è un JSON valido.');
    }
    if (root is! Map<String, dynamic> || root['format'] != format) {
      throw const BackupFormatException(
        'Il file non è un backup di NTAKO Timer.',
      );
    }
    final version = root['version'];
    if (version is! int || version > formatVersion) {
      throw const BackupFormatException(
        'Backup creato da una versione più recente dell\'app: aggiornala.',
      );
    }

    final rows = _Rows(root);
    return _Backup(
      categories: rows.list('categories', (r) {
        return CategoriesCompanion(
          id: Value(r.uuid('id')),
          name: Value(r.string('name', maxLength: 100)),
          color: Value(r.color('color')),
          createdAt: Value(r.timestamp('created_at')),
          updatedAt: Value(r.timestamp('updated_at')),
          deletedAt: Value(r.optionalTimestamp('deleted_at')),
          isSynced: const Value(false),
        );
      }),
      tasks: rows.list('tasks', (r) {
        return TasksCompanion(
          id: Value(r.uuid('id')),
          categoryId: Value(r.optionalUuid('category_id')),
          // The server accepts empty titles, so a server export may have them.
          title: Value(r.string('title', maxLength: 255, allowEmpty: true)),
          description: Value(r.optionalString('description')),
          isCompleted: Value(r.boolean('is_completed')),
          createdAt: Value(r.timestamp('created_at')),
          updatedAt: Value(r.timestamp('updated_at')),
          deletedAt: Value(r.optionalTimestamp('deleted_at')),
          isSynced: const Value(false),
        );
      }),
      sessions: rows.list('sessions', (r) {
        return SessionsCompanion(
          id: Value(r.uuid('id')),
          taskId: Value(r.optionalUuid('task_id')),
          type: Value(r.string('type', maxLength: 20)),
          startedAt: Value(r.timestamp('started_at')),
          endedAt: Value(r.optionalTimestamp('ended_at')),
          durationSeconds: Value(r.duration('duration_seconds')),
          isCompleted: Value(r.boolean('is_completed')),
          createdAt: Value(r.timestamp('created_at')),
          isSynced: const Value(false),
        );
      }),
    );
  }
}

class _Backup {
  final List<CategoriesCompanion> categories;
  final List<TasksCompanion> tasks;
  final List<SessionsCompanion> sessions;

  _Backup({
    required this.categories,
    required this.tasks,
    required this.sessions,
  });
}

/// Iterates the row lists of a backup, rejecting the whole file on the
/// first invalid value. The limits mirror backend/api/sync/push.php and the
/// MySQL schema: a row the server would refuse would block sync for good.
class _Rows {
  final Map<String, dynamic> root;

  _Rows(this.root);

  List<T> list<T>(String key, T Function(_Row) build) {
    final value = root[key] ?? const [];
    if (value is! List) throw _invalid(key);
    return [
      for (final (i, row) in value.indexed)
        if (row is Map<String, dynamic>)
          build(_Row(row, '$key[$i]'))
        else
          throw _invalid('$key[$i]'),
    ];
  }
}

class _Row {
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _color = RegExp(r'^#[0-9a-f]{6}$', caseSensitive: false);
  static const _maxInt32 = 2147483647;

  final Map<String, dynamic> data;
  final String where;

  _Row(this.data, this.where);

  T _check<T>(String key, bool Function(T) valid) {
    final v = data[key];
    if (v is T && valid(v)) return v;
    throw _invalid('$where.$key');
  }

  String uuid(String key) => _check<String>(key, _uuid.hasMatch);

  String? optionalUuid(String key) => data[key] == null ? null : uuid(key);

  String string(
    String key, {
    required int maxLength,
    bool allowEmpty = false,
  }) => _check<String>(
    key,
    (s) => (allowEmpty || s.isNotEmpty) && s.length <= maxLength,
  );

  String? optionalString(String key) =>
      data[key] == null ? null : _check<String>(key, (_) => true);

  String color(String key) => _check<String>(key, _color.hasMatch);

  bool boolean(String key) => _check<bool>(key, (_) => true);

  int timestamp(String key) => _check<int>(key, (n) => n >= 0);

  int? optionalTimestamp(String key) =>
      data[key] == null ? null : timestamp(key);

  int duration(String key) => _check<int>(key, (n) => n >= 0 && n <= _maxInt32);
}

BackupFormatException _invalid(String where) => BackupFormatException(
  'Backup non valido: campo "$where" mancante o errato.',
);
