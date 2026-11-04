import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'tables.dart';
import 'daos/categories_dao.dart';
import 'daos/tasks_dao.dart';
import 'daos/sessions_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/presences_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Categories, Tasks, Sessions, Settings, Presences],
  daos: [CategoriesDao, TasksDao, SessionsDao, SettingsDao, PresencesDao],
)
class AppDatabase extends _$AppDatabase {
  /// [executor] is for tests (e.g. an in-memory database).
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from >= 3) {
        // 4: presence detection. Additive: existing data is kept.
        if (from < 4) await m.createTable(presences);
        return;
      }
      // Older, pre-release schemas: destroy and recreate.
      for (final table in allTables) {
        await m.deleteTable(table.actualTableName);
      }
      await m.createAll();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      if (!kIsWeb) {
        // The Android presence service opens this file too: wait for the
        // other connection's lock instead of failing, and let it read
        // while this one writes.
        await customStatement('PRAGMA busy_timeout = 5000');
        await customStatement('PRAGMA journal_mode = WAL');
      }
    },
  );

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'workadoro_db',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
        onResult: (r) => debugPrint('[Drift] storage: $r'),
      ),
    );
  }
}
