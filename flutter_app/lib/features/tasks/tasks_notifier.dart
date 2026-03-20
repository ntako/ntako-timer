import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../sync/sync_service.dart';

part 'tasks_notifier.g.dart';

const _uuid = Uuid();

/// Live stream di task attivi (non eliminati), ordinati dal più recente.
@riverpod
Stream<List<Task>> activeTasks(ActiveTasksRef ref) =>
    ref.watch(appDatabaseProvider).tasksDao.watchActiveTasks();

/// Live map of taskId → total tracked seconds (completed sessions only).
@riverpod
Stream<Map<String, int>> taskTotals(TaskTotalsRef ref) =>
    ref.watch(appDatabaseProvider).sessionsDao.watchTaskTotals();

@riverpod
class TasksNotifier extends _$TasksNotifier {
  @override
  void build() {}

  Future<String> createTask({
    required String title,
    String? description,
    String? categoryId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    await ref.read(appDatabaseProvider).tasksDao.insertTask(
      TasksCompanion(
        id: Value(id),
        title: Value(title),
        type: const Value('tracker'),
        description: Value(description),
        categoryId: Value(categoryId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    // Push to server in background so Cardputer can pick it up on next sync
    ref.read(syncServiceProvider).sync().ignore();
    return id;
  }

  Future<void> updateTask({
    required String id,
    String? title,
    String? description,
    String? categoryId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.read(appDatabaseProvider).tasksDao.updateTask(
      TasksCompanion(
        id: Value(id),
        title: title != null ? Value(title) : const Value.absent(),
        description:
            description != null ? Value(description) : const Value.absent(),
        categoryId:
            categoryId != null ? Value(categoryId) : const Value.absent(),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
  }

  /// Full edit: title, description, and category (categoryId can be null to remove).
  Future<void> saveTaskEdit({
    required String id,
    required String title,
    String? description,
    required String? categoryId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.read(appDatabaseProvider).tasksDao.updateTask(
      TasksCompanion(
        id: Value(id),
        title: Value(title),
        description: Value(description),
        categoryId: Value(categoryId),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
    ref.read(syncServiceProvider).sync().ignore();
  }

  Future<void> toggleComplete(Task task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.read(appDatabaseProvider).tasksDao.updateTask(
      TasksCompanion(
        id: Value(task.id),
        isCompleted: Value(!task.isCompleted),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
  }

  Future<void> deleteTask(String id) async {
    await ref.read(appDatabaseProvider).tasksDao.softDeleteTask(id);
  }

  Future<void> deleteAllCompleted() async {
    await ref.read(appDatabaseProvider).tasksDao.deleteCompletedTasks();
  }

  /// Explicitly sets the categoryId for a task (supports setting to null).
  Future<void> updateTaskCategory(String id, String? categoryId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.read(appDatabaseProvider).tasksDao.updateTask(
      TasksCompanion(
        id: Value(id),
        categoryId: Value(categoryId),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
    ref.read(syncServiceProvider).sync().ignore();
  }
}
