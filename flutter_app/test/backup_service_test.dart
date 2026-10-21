import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntako_timer/core/database/app_database.dart';
import 'package:ntako_timer/features/backup/backup_service.dart';
import 'package:ntako_timer/features/timer/timer_notifier.dart';

const catId = '11111111-1111-4111-8111-111111111111';
const taskId = '22222222-2222-4222-8222-222222222222';
const sessionId = '33333333-3333-4333-8333-333333333333';
const otherId = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> backupJson({
  List<Map<String, dynamic>> categories = const [],
  List<Map<String, dynamic>> tasks = const [],
  List<Map<String, dynamic>> sessions = const [],
}) => {
  'format': 'ntako-timer-backup',
  'version': 1,
  'exported_at': 0,
  'categories': categories,
  'tasks': tasks,
  'sessions': sessions,
};

Map<String, dynamic> category({
  String id = catId,
  int updatedAt = 1000,
  String name = 'Lavoro',
}) => {
  'id': id,
  'name': name,
  'color': '#6366f1',
  'created_at': 1000,
  'updated_at': updatedAt,
  'deleted_at': null,
};

Map<String, dynamic> task({
  String id = taskId,
  String? categoryId = catId,
  int updatedAt = 1000,
  String title = 'Task',
}) => {
  'id': id,
  'category_id': categoryId,
  'title': title,
  'description': null,
  'is_completed': false,
  'created_at': 1000,
  'updated_at': updatedAt,
  'deleted_at': null,
};

Map<String, dynamic> session({
  String id = sessionId,
  String? taskId = taskId,
  int? endedAt = 61000,
  int duration = 60,
}) => {
  'id': id,
  'task_id': taskId,
  'type': 'tracking',
  'started_at': 1000,
  'ended_at': endedAt,
  'duration_seconds': duration,
  'is_completed': endedAt != null,
  'created_at': 1000,
};

void main() {
  late AppDatabase db;
  late BackupService backup;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    backup = BackupService(db);
  });

  tearDown(() => db.close());

  Future<ImportResult> import(Map<String, dynamic> json) =>
      backup.importJson(jsonEncode(json));

  test(
    'export then import into an empty database restores everything',
    () async {
      await import(
        backupJson(
          categories: [category()],
          tasks: [
            task(),
            task(id: otherId, title: 'Deleted')..['deleted_at'] = 5000,
          ],
          sessions: [session()],
        ),
      );
      final exported = await backup.exportJson();

      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      final result = await BackupService(fresh).importJson(exported);

      expect(result.categories.added, 1);
      expect(result.tasks.added, 2);
      expect(result.sessions.added, 1);
      final a = jsonDecode(exported) as Map;
      final b = jsonDecode(await BackupService(fresh).exportJson()) as Map;
      for (final key in ['categories', 'tasks', 'sessions']) {
        expect(b[key], a[key], reason: key);
      }
      final t = await fresh.tasksDao.getTaskById(otherId);
      expect(t!.deletedAt, 5000);
      expect(t.isSynced, isFalse, reason: 'imported rows must be pushed');
    },
  );

  test('merge keeps the most recent version and deletes nothing', () async {
    await import(
      backupJson(
        categories: [category(updatedAt: 2000, name: 'Local newer')],
        tasks: [task(updatedAt: 1000, title: 'Local older')],
      ),
    );
    final result = await import(
      backupJson(
        categories: [category(updatedAt: 1500, name: 'Imported older')],
        tasks: [
          task(updatedAt: 3000, title: 'Imported newer'),
          task(id: otherId, title: 'New'),
        ],
      ),
    );

    expect(
      (await db.categoriesDao.getCategoryById(catId))!.name,
      'Local newer',
    );
    expect((await db.tasksDao.getTaskById(taskId))!.title, 'Imported newer');
    expect(await db.tasksDao.getTaskById(otherId), isNotNull);
    expect(result.categories.unchanged, 1);
    expect(result.tasks.updated, 1);
    expect(result.tasks.added, 1);

    final again = await import(backupJson(tasks: [task(updatedAt: 3000)]));
    expect(again.changedAnything, isFalse);
  });

  test(
    'sessions merge like the server; the active one is left alone',
    () async {
      await import(
        backupJson(
          categories: [category()],
          tasks: [task()],
          sessions: [
            session(endedAt: null, duration: 0),
            session(id: otherId, endedAt: null, duration: 0),
          ],
        ),
      );
      await db.settingsDao.setValue(activeSessionSettingsKey, otherId);

      final result = await import(
        backupJson(
          sessions: [
            session(endedAt: 61000, duration: 60),
            session(id: otherId, endedAt: 61000, duration: 60),
          ],
        ),
      );

      final closed = (await db.sessionsDao.getSessionById(sessionId))!;
      expect(closed.endedAt, 61000);
      expect(closed.durationSeconds, 60);
      expect(closed.isCompleted, isTrue);
      expect(closed.isSynced, isFalse);
      expect((await db.sessionsDao.getSessionById(otherId))!.endedAt, isNull);
      expect(result.sessions.updated, 1);
      expect(result.sessions.unchanged, 1);
    },
  );

  test('references to missing rows are dropped instead of failing', () async {
    await import(
      backupJson(
        tasks: [task(categoryId: otherId)],
        sessions: [session(taskId: otherId)],
      ),
    );

    expect((await db.tasksDao.getTaskById(taskId))!.categoryId, isNull);
    expect((await db.sessionsDao.getSessionById(sessionId))!.taskId, isNull);
  });

  test('an invalid file is rejected without writing anything', () async {
    Future<void> expectRejected(Object json, String messagePart) => expectLater(
      backup.importJson(json is String ? json : jsonEncode(json)),
      throwsA(
        isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains(messagePart),
        ),
      ),
    );

    await expectRejected('not json', 'JSON valido');
    await expectRejected({'format': 'other'}, 'non è un backup');
    await expectRejected(backupJson()..['version'] = 2, 'più recente');
    await expectRejected(
      backupJson(
        categories: [category()],
        tasks: [task(id: 'not-a-uuid')],
      ),
      'tasks[0].id',
    );
    await expectRejected(
      backupJson(sessions: [session(duration: 1 << 40)]),
      'duration_seconds',
    );

    expect(
      await db.categoriesDao.getCategoryById(catId),
      isNull,
      reason: 'the valid category before the bad task must not be kept',
    );
  });

  test('CSV export: finished sessions only, escaped, Excel-friendly', () async {
    await import(
      backupJson(
        categories: [category(name: 'Clienti')],
        tasks: [task(title: 'Riunione; "kickoff"')],
        sessions: [
          session(duration: 3725),
          session(id: otherId, endedAt: null, duration: 0),
        ],
      ),
    );

    final csv = await backup.exportSessionsCsv();
    final lines = csv.split('\r\n');

    expect(csv.startsWith('﻿'), isTrue);
    expect(lines[0], '﻿Data;Inizio;Fine;Durata;Minuti;Task;Categoria');
    expect(lines, hasLength(3), reason: 'header + 1 finished session + ""');
    expect(lines[1], endsWith(';1:02:05;62;"Riunione; ""kickoff""";Clienti'));
  });
}
