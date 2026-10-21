import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';

part 'sync_service.g.dart';

// Kept alive so every caller shares one instance and therefore one lock.
@Riverpod(keepAlive: true)
SyncService syncService(SyncServiceRef ref) => SyncService(
  db: ref.watch(appDatabaseProvider),
  api: ref.watch(apiClientProvider),
);

class SyncService {
  final AppDatabase db;
  final ApiClient api;

  SyncService({required this.db, required this.api});

  static const _cursorKey = 'sync_cursor';
  static const _pageSize = 200;

  Future<void>? _running;
  bool _runAgain = false;

  /// Pushes local changes, then pulls remote ones.
  ///
  /// Only one sync runs at a time. A call made while one is running doesn't
  /// start a second, racing one: it schedules one more round after the
  /// current one, so a change saved mid-sync still gets pushed.
  Future<void> sync() {
    final running = _running;
    if (running != null) {
      _runAgain = true;
      return running;
    }
    return _running = _syncRounds().whenComplete(() => _running = null);
  }

  /// Forget how far we've pulled, so the next sync downloads everything.
  /// Needed when the account changes.
  Future<void> resetCursor() => db.settingsDao.deleteValue(_cursorKey);

  Future<void> _syncRounds() async {
    do {
      _runAgain = false;
      await _push();
      await _pull();
    } while (_runAgain);
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
        'type': 'tracker',
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
      final id = m['client_id'] as String;
      await db.categoriesDao.markCategorySynced(
        id,
        m['server_id'] as int,
        categories.firstWhere((c) => c.id == id).updatedAt,
      );
    }

    for (final st in (result['synced_tasks'] as List)) {
      final m = st as Map<String, dynamic>;
      final id = m['client_id'] as String;
      await db.tasksDao.markTaskSynced(
        id,
        m['server_id'] as int,
        tasks.firstWhere((t) => t.id == id).updatedAt,
      );
    }

    for (final ss in (result['synced_sessions'] as List)) {
      final m = ss as Map<String, dynamic>;
      final id = m['client_id'] as String;
      await db.sessionsDao.markSessionSynced(
        id,
        m['server_id'] as int,
        sessions.firstWhere((s) => s.id == id).endedAt,
      );
    }
  }

  // ----------------------------------------------------------------
  // Pull: fetch changes from server since the stored cursor
  // ----------------------------------------------------------------

  Future<void> _pull() async {
    var cursor = int.tryParse(await db.settingsDao.getValue(_cursorKey) ?? '') ?? 0;

    while (true) {
      final result = await api.get(
        '/sync/pull',
        params: {'cursor': '$cursor', 'limit': '$_pageSize'},
      );
      cursor = result['cursor'] as int;

      // Merge the page and advance the cursor together, so an interrupted
      // sync resumes from the last fully applied page.
      await db.transaction(() async {
        await _mergeCategories(result['categories'] as List);
        await _mergeTasks(result['tasks'] as List);
        await _mergeSessions(result['sessions'] as List);
        await db.settingsDao.setValue(_cursorKey, '$cursor');
      });

      if (result['has_more'] != true) break;
    }
  }

  Future<void> _mergeCategories(List rows) async {
    for (final c in rows) {
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
  }

  Future<void> _mergeTasks(List rows) async {
    for (final t in rows) {
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
          type: const Value('tracker'),
          isCompleted: Value((m['is_completed'] as int) == 1),
          createdAt: Value(m['created_at'] as int),
          updatedAt: Value(m['updated_at'] as int),
          deletedAt: Value(m['deleted_at'] as int?),
          isSynced: const Value(true),
        ),
      );
    }
  }

  Future<void> _mergeSessions(List rows) async {
    for (final s in rows) {
      final m = s as Map<String, dynamic>;
      final local =
          await db.sessionsDao.getSessionById(m['client_id'] as String);

      // A local change not pushed yet (e.g. stopped mid-sync) is newer than
      // the server copy. Keep it: the next push sends it and the server merges.
      if (local != null && !local.isSynced) continue;

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
  }
}
