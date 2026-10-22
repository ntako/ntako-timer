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

  Future<Session?> getSessionById(String id) =>
      (select(sessions)..where((s) => s.id.equals(id))).getSingleOrNull();

  /// Only matches if the session hasn't been closed since the push was sent
  /// ([pushedEndedAt] null = it was still open), so a stop made while the
  /// push was in flight stays pending.
  Future<void> markSessionSynced(
    String clientId,
    int serverId,
    int? pushedEndedAt,
  ) =>
      (update(sessions)
            ..where(
              (s) =>
                  s.id.equals(clientId) &
                  (pushedEndedAt == null
                      ? s.endedAt.isNull()
                      : s.endedAt.equals(pushedEndedAt)),
            ))
          .write(
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

  /// Watch sessions not ended yet: this device's running timer plus those
  /// of other devices, received by sync.
  Stream<List<Session>> watchOpenSessions() =>
      (select(sessions)..where((s) => s.endedAt.isNull())).watch();

  Future<List<Session>> getOpenSessions() =>
      (select(sessions)..where((s) => s.endedAt.isNull())).get();

  /// Watch one session (null if missing).
  Stream<Session?> watchSession(String id) =>
      (select(sessions)..where((s) => s.id.equals(id))).watchSingleOrNull();

  /// Watch every session (history report filters them in memory).
  Stream<List<Session>> watchAllSessions() => select(sessions).watch();

  /// Watch the most recent sessions (all statuses), newest first.
  Stream<List<Session>> watchRecentSessions({int limit = 100}) =>
      (select(sessions)
            ..orderBy([(s) => OrderingTerm.desc(s.startedAt)])
            ..limit(limit))
          .watch();

  /// Watch total tracked seconds per task (completed sessions only).
  /// Returns a map of taskId → totalSeconds, updated reactively.
  Stream<Map<String, int>> watchTaskTotals() {
    final query = customSelect(
      'SELECT task_id, CAST(SUM(duration_seconds) AS INTEGER) AS total '
      'FROM sessions '
      'WHERE task_id IS NOT NULL AND is_completed = 1 '
      'GROUP BY task_id',
      readsFrom: {sessions},
    );
    return query.watch().map(
      (rows) => {
        for (final row in rows)
          row.read<String>('task_id'): row.read<int>('total'),
      },
    );
  }
}
