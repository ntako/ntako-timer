import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';

part 'tasks_notifier.g.dart';

const _uuid = Uuid();

/// Live stream di task attivi (non eliminati), ordinati dal più recente.
@riverpod
Stream<List<Task>> activeTasks(ActiveTasksRef ref) =>
    ref.watch(appDatabaseProvider).tasksDao.watchActiveTasks();

@riverpod
class TasksNotifier extends _$TasksNotifier {
  @override
  void build() {}

  Future<String> createTask({
    required String title,
    required String type, // 'pomodoro' | 'tracker'
    String? description,
    String? categoryId,
    int pomodoroGoal = 4,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    await ref.read(appDatabaseProvider).tasksDao.insertTask(
      TasksCompanion(
        id: Value(id),
        title: Value(title),
        type: Value(type),
        description: Value(description),
        categoryId: Value(categoryId),
        pomodoroGoal: Value(pomodoroGoal),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> updateTask({
    required String id,
    String? title,
    String? description,
    String? categoryId,
    int? pomodoroGoal,
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
        pomodoroGoal:
            pomodoroGoal != null ? Value(pomodoroGoal) : const Value.absent(),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
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
}
