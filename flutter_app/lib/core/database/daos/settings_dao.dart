import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables.dart';

part 'settings_dao.g.dart';

@DriftAccessor(tables: [Settings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  Future<String?> getValue(String key) async {
    final row = await (select(settings)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value) =>
      into(settings).insertOnConflictUpdate(
        SettingsCompanion(key: Value(key), value: Value(value)),
      );

  Future<void> deleteValue(String key) =>
      (delete(settings)..where((s) => s.key.equals(key))).go();
}
