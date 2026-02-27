import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables.dart';

part 'tasks_dao.g.dart';

@DriftAccessor(tables: [Tasks])
class TasksDao extends DatabaseAccessor<AppDatabase> with _$TasksDaoMixin {
  TasksDao(super.db);

  /// Watch all non-deleted tasks, newest first.
  Stream<List<Task>> watchActiveTasks() =>
      (select(tasks)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  /// Watch non-deleted tasks for a specific category.
  Stream<List<Task>> watchTasksByCategory(String categoryId) =>
      (select(tasks)
            ..where(
              (t) =>
                  t.deletedAt.isNull() &
                  t.categoryId.equals(categoryId),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  /// Watch non-deleted tasks with no category assigned.
  Stream<List<Task>> watchUncategorizedTasks() =>
      (select(tasks)
            ..where(
              (t) => t.deletedAt.isNull() & t.categoryId.isNull(),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<Task?> getTaskById(String id) =>
      (select(tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> insertTask(TasksCompanion task) =>
      into(tasks).insert(task, mode: InsertMode.insertOrReplace);

  Future<void> updateTask(TasksCompanion task) =>
      (update(tasks)..where((t) => t.id.equals(task.id.value))).write(task);

  Future<void> softDeleteTask(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (update(tasks)..where((t) => t.id.equals(id))).write(
      TasksCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
  }

  Future<void> deleteCompletedTasks() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (update(tasks)
          ..where((t) => t.isCompleted.equals(true) & t.deletedAt.isNull()))
        .write(
      TasksCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
  }

  Future<List<Task>> getUnsyncedTasks() =>
      (select(tasks)..where((t) => t.isSynced.equals(false))).get();

  Future<void> markTaskSynced(String clientId, int serverId) =>
      (update(tasks)..where((t) => t.id.equals(clientId))).write(
        TasksCompanion(
          serverId: Value(serverId),
          isSynced: const Value(true),
        ),
      );
}
