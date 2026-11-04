import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables.dart';

part 'presences_dao.g.dart';

@DriftAccessor(tables: [Presences])
class PresencesDao extends DatabaseAccessor<AppDatabase>
    with _$PresencesDaoMixin {
  PresencesDao(super.db);

  Future<void> insertPresence(PresencesCompanion p) =>
      into(presences).insert(p, mode: InsertMode.insertOrReplace);

  Future<List<Presence>> getOpen() =>
      (select(presences)..where((p) => p.exitedAt.isNull())).get();

  Future<void> markSeen(String id, int at) =>
      (update(presences)..where((p) => p.id.equals(id))).write(
        PresencesCompanion(lastSeenAt: Value(at), isSynced: const Value(false)),
      );

  /// Closes a stay; [at] is also its last detection.
  Future<void> closeStay(String id, int at) =>
      (update(presences)..where((p) => p.id.equals(id))).write(
        PresencesCompanion(
          exitedAt: Value(at),
          lastSeenAt: Value(at),
          isSynced: const Value(false),
        ),
      );

  Future<List<Presence>> getUnsynced() =>
      (select(presences)..where((p) => p.isSynced.equals(false))).get();

  /// Only if the stay hasn't changed since it was pushed, so a detection
  /// made while the push was in flight stays pending.
  Future<void> markSynced(Presence pushed, int serverId) =>
      (update(presences)..where(
            (p) =>
                p.id.equals(pushed.id) &
                p.lastSeenAt.equals(pushed.lastSeenAt) &
                (pushed.exitedAt == null
                    ? p.exitedAt.isNull()
                    : p.exitedAt.equals(pushed.exitedAt!)),
          ))
          .write(
            PresencesCompanion(
              serverId: Value(serverId),
              isSynced: const Value(true),
            ),
          );

  Future<List<Presence>> getAll() => select(presences).get();

  /// Most recent stays first.
  Stream<List<Presence>> watchRecent({int limit = 50}) =>
      (select(presences)
            ..orderBy([(p) => OrderingTerm.desc(p.enteredAt)])
            ..limit(limit))
          .watch();
}
