import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../sync/sync_service.dart';

part 'categories_notifier.g.dart';

const _uuid = Uuid();

/// Palette di 8 colori predefiniti per le categorie.
const kCategoryColors = [
  '#6366f1', // indigo
  '#ec4899', // pink
  '#f59e0b', // amber
  '#10b981', // emerald
  '#3b82f6', // blue
  '#ef4444', // red
  '#8b5cf6', // violet
  '#6b7280', // gray
];

/// Live stream di categorie attive (non eliminate).
@riverpod
Stream<List<Category>> activeCategories(ActiveCategoriesRef ref) =>
    ref.watch(appDatabaseProvider).categoriesDao.watchActiveCategories();

@riverpod
class CategoriesNotifier extends _$CategoriesNotifier {
  @override
  void build() {}

  Future<String> createCategory({
    required String name,
    String color = '#6366f1',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    await ref.read(appDatabaseProvider).categoriesDao.insertCategory(
      CategoriesCompanion(
        id: Value(id),
        name: Value(name),
        color: Value(color),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> updateCategory({
    required String id,
    String? name,
    String? color,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.read(appDatabaseProvider).categoriesDao.updateCategory(
      CategoriesCompanion(
        id: Value(id),
        name: name != null ? Value(name) : const Value.absent(),
        color: color != null ? Value(color) : const Value.absent(),
        updatedAt: Value(now),
        isSynced: const Value(false),
      ),
    );
    ref.read(syncServiceProvider).sync().ignore();
  }

  Future<void> deleteCategory(String id) async {
    await ref.read(appDatabaseProvider).categoriesDao.softDeleteCategory(id);
  }
}
