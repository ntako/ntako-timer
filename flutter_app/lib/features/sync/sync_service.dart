import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';

part 'sync_service.g.dart';

@riverpod
SyncService syncService(SyncServiceRef ref) => SyncService(
  db: ref.watch(appDatabaseProvider),
  api: ref.watch(apiClientProvider),
);

class SyncService {
  final AppDatabase db;
  final ApiClient api;

  SyncService({required this.db, required this.api});

  Future<void> sync() async {
    await _push();
    await _pull();
  }

  // ----------------------------------------------------------------
  // Push: send unsynced local records to server
  // ----------------------------------------------------------------

  Future<void> _push() async {
    final categories = await db.categoriesDao.getUnsyncedCategories();
    final tasks = await db.tasksDao.getUnsyncedTasks();
    final sessions = await db.sessionsDao.getUnsyncedSessions();

    if (categories.isEmpty && tasks.isEmpty && sessions.isEmpty) return;

    final result = await api.post('/sync/push', {
      'categories': categories.map((c) => {
        'client_id': c.id,
        'name': c.name,
        'color': c.color,
        'created_at': c.createdAt,
        'updated_at': c.updatedAt,
        'deleted_at': c.deletedAt,
      }).toList(),
      'tasks': tasks.map((t) => {
        'client_id': t.id,
        'category_client_id': t.categoryId,
        'title': t.title,
        'description': t.description,
        'type': t.type,
        'pomodoro_goal': t.pomodoroGoal,
        'pomodoros_done': t.pomodorosDone,
        'is_completed': t.isCompleted ? 1 : 0,
        'created_at': t.createdAt,
        'updated_at': t.updatedAt,
        'deleted_at': t.deletedAt,
      }).toList(),
      'sessions': sessions.map((s) => {
        'client_id': s.id,
        'task_client_id': s.taskId,
        'type': s.type,
        'started_at': s.startedAt,
        'ended_at': s.endedAt,
        'duration_seconds': s.durationSeconds,
        'is_completed': s.isCompleted ? 1 : 0,
        'created_at': s.createdAt,
      }).toList(),
    });

    for (final sc in (result['synced_categories'] as List)) {
      final m = sc as Map<String, dynamic>;
      await db.categoriesDao.markCategorySynced(
        m['client_id'] as String,
        m['server_id'] as int,
      );
    }

    for (final st in (result['synced_tasks'] as List)) {
      final m = st as Map<String, dynamic>;
      await db.tasksDao.markTaskSynced(
        m['client_id'] as String,
        m['server_id'] as int,
      );
    }

    for (final ss in (result['synced_sessions'] as List)) {
      final m = ss as Map<String, dynamic>;
      await db.sessionsDao.markSessionSynced(
        m['client_id'] as String,
        m['server_id'] as int,
      );
    }
  }

  // ----------------------------------------------------------------
  // Pull: fetch changes from server since last sync
  // ----------------------------------------------------------------

  Future<void> _pull() async {
    final lastSyncStr = await db.settingsDao.getValue('last_sync_at');
    final since = lastSyncStr != null ? int.parse(lastSyncStr) : 0;

    final result = await api.get(
      '/sync/pull',
      params: {'since': since.toString()},
    );

    final serverTime = result['server_time'] as int;

    // ── Merge categories ──────────────────────────────────────────────
    for (final c in (result['categories'] as List)) {
      final m = c as Map<String, dynamic>;
      final local =
          await db.categoriesDao.getCategoryById(m['client_id'] as String);

      if (local != null && local.updatedAt > (m['updated_at'] as int)) {
        continue;
      }

      await db.categoriesDao.insertCategory(
        CategoriesCompanion(
          id: Value(m['client_id'] as String),
          serverId: Value(m['id'] as int),
          name: Value(m['name'] as String),
          color: Value((m['color'] as String?) ?? '#6366f1'),
          createdAt: Value(m['created_at'] as int),
          updatedAt: Value(m['updated_at'] as int),
          deletedAt: Value(m['deleted_at'] as int?),
          isSynced: const Value(true),
        ),
      );
    }

    // ── Merge tasks ───────────────────────────────────────────────────
    for (final t in (result['tasks'] as List)) {
      final m = t as Map<String, dynamic>;
      final local = await db.tasksDao.getTaskById(m['client_id'] as String);

      if (local != null && local.updatedAt > (m['updated_at'] as int)) {
        continue;
      }

      await db.tasksDao.insertTask(
        TasksCompanion(
          id: Value(m['client_id'] as String),
          serverId: Value(m['id'] as int),
          categoryId: Value(m['category_client_id'] as String?),
          title: Value(m['title'] as String),
          description: Value(m['description'] as String?),
          type: Value((m['type'] as String?) ?? 'pomodoro'),
          pomodoroGoal: Value(m['pomodoro_goal'] as int? ?? 4),
          pomodorosDone: Value(m['pomodoros_done'] as int? ?? 0),
          isCompleted: Value((m['is_completed'] as int) == 1),
          createdAt: Value(m['created_at'] as int),
          updatedAt: Value(m['updated_at'] as int),
          deletedAt: Value(m['deleted_at'] as int?),
          isSynced: const Value(true),
        ),
      );
    }

    // ── Merge sessions ────────────────────────────────────────────────
    for (final s in (result['sessions'] as List)) {
      final m = s as Map<String, dynamic>;
      await db.sessionsDao.insertSession(
        SessionsCompanion(
          id: Value(m['client_id'] as String),
          serverId: Value(m['id'] as int),
          taskId: Value(m['task_client_id'] as String?),
          type: Value(m['type'] as String),
          startedAt: Value(m['started_at'] as int),
          endedAt: Value(m['ended_at'] as int?),
          durationSeconds: Value(m['duration_seconds'] as int),
          isCompleted: Value((m['is_completed'] as int) == 1),
          createdAt: Value(m['created_at'] as int),
          isSynced: const Value(true),
        ),
      );
    }

    await db.settingsDao.setValue('last_sync_at', serverTime.toString());
  }
}
