import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables.dart';

part 'sessions_dao.g.dart';

@DriftAccessor(tables: [Sessions])
class SessionsDao extends DatabaseAccessor<AppDatabase>
    with _$SessionsDaoMixin {
  SessionsDao(super.db);

  Future<void> insertSession(SessionsCompanion session) =>
      into(sessions).insert(session, mode: InsertMode.insertOrReplace);

  Future<void> completeSession(String id, int endedAt) =>
      (update(sessions)..where((s) => s.id.equals(id))).write(
        SessionsCompanion(
          endedAt: Value(endedAt),
          isCompleted: const Value(true),
          isSynced: const Value(false),
        ),
      );

  Future<List<Session>> getUnsyncedSessions() =>
      (select(sessions)..where((s) => s.isSynced.equals(false))).get();

  Future<List<Session>> getSessionsInRange(int fromMs, int toMs) =>
      (select(sessions)
            ..where(
              (s) =>
                  s.startedAt.isBiggerOrEqualValue(fromMs) &
                  s.startedAt.isSmallerOrEqualValue(toMs) &
                  s.isCompleted.equals(true),
            ))
          .get();

  Future<void> markSessionSynced(String clientId, int serverId) =>
      (update(sessions)..where((s) => s.id.equals(clientId))).write(
        SessionsCompanion(
          serverId: Value(serverId),
          isSynced: const Value(true),
        ),
      );

  /// Complete a tracking session, updating both endedAt and the actual duration.
  Future<void> completeSessionWithDuration(
    String id,
    int endedAt,
    int durationSeconds,
  ) =>
      (update(sessions)..where((s) => s.id.equals(id))).write(
        SessionsCompanion(
          endedAt: Value(endedAt),
          durationSeconds: Value(durationSeconds),
          isCompleted: const Value(true),
          isSynced: const Value(false),
        ),
      );

  /// Watch the most recent sessions (all statuses), newest first.
  Stream<List<Session>> watchRecentSessions({int limit = 100}) =>
      (select(sessions)
            ..orderBy([(s) => OrderingTerm.desc(s.startedAt)])
            ..limit(limit))
          .watch();
}
