import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'tables.dart';
import 'daos/categories_dao.dart';
import 'daos/tasks_dao.dart';
import 'daos/sessions_dao.dart';
import 'daos/settings_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Categories, Tasks, Sessions, Settings],
  daos: [CategoriesDao, TasksDao, SessionsDao, SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // v1 → v2: add categories, extend tasks, rename sessions table
        await m.createTable(categories);
        await m.addColumn(tasks, tasks.categoryId);
        await m.addColumn(tasks, tasks.type);
        await m.renameTable(sessions, 'pomodoro_sessions');
      }
    },
    beforeOpen: (details) async {
      // SQLite does not enforce foreign keys by default — enable per connection.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'ntako_timer_db',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
        onResult: (r) => debugPrint('[Drift] storage: $r'),
      ),
    );
  }
}
