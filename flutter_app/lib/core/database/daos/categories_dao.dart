import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables.dart';

part 'categories_dao.g.dart';

@DriftAccessor(tables: [Categories])
class CategoriesDao extends DatabaseAccessor<AppDatabase>
    with _$CategoriesDaoMixin {
  CategoriesDao(super.db);

  /// Watch all non-deleted categories, newest first.
  Stream<List<Category>> watchActiveCategories() =>
      (select(categories)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.asc(c.name)]))
          .watch();

  /// Watch all categories, deleted ones included (history still names them).
  Stream<List<Category>> watchAllCategories() => select(categories).watch();

  Future<Category?> getCategoryById(String id) =>
      (select(categories)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<void> insertCategory(CategoriesCompanion cat) =>
      into(categories).insert(cat, mode: InsertMode.insertOrReplace);

  Future<void> updateCategory(CategoriesCompanion cat) =>
      (update(categories)..where((c) => c.id.equals(cat.id.value))).write(cat);

  Future<void> softDeleteCategory(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (update(categories)..where((c) => c.id.equals(id))).write(
      CategoriesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
  }

  Future<List<Category>> getUnsyncedCategories() =>
      (select(categories)..where((c) => c.isSynced.equals(false))).get();

  /// Only matches if the row still has the [pushedUpdatedAt] that was sent,
  /// so an edit made while the push was in flight stays pending.
  Future<void> markCategorySynced(
    String clientId,
    int serverId,
    int pushedUpdatedAt,
  ) =>
      (update(categories)
            ..where(
              (c) => c.id.equals(clientId) & c.updatedAt.equals(pushedUpdatedAt),
            ))
          .write(
        CategoriesCompanion(
          serverId: Value(serverId),
          isSynced: const Value(true),
        ),
      );
}
