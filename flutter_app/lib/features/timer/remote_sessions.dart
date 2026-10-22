import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import 'timer_notifier.dart';

/// Sessions without an end: this device's running timer and those of other
/// devices, as last received by sync.
final openSessionsProvider = StreamProvider<List<Session>>(
  (ref) => ref.watch(appDatabaseProvider).sessionsDao.watchOpenSessions(),
);

/// Timers running on other devices, oldest first.
///
/// What the other device does after its last push (a pause in particular)
/// isn't known here: the elapsed time shown counts from the start.
final remoteRunningProvider = Provider<List<Session>>((ref) {
  final mine = ref.watch(
    timerNotifierProvider.select((s) => s.activeSessionId),
  );
  final open = ref.watch(openSessionsProvider).valueOrNull ?? const [];
  return open.where((s) => s.id != mine).toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
});

/// Task titles by id, deleted tasks included (a remote timer may run on
/// any task).
final taskTitlesProvider = StreamProvider<Map<String, String>>(
  (ref) => ref
      .watch(appDatabaseProvider)
      .tasksDao
      .watchAllTasks()
      .map((tasks) => {for (final t in tasks) t.id: t.title}),
);

/// "1:02:05" / "12:30".
String clock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600 ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Seconds since a remote session started.
int remoteElapsed(Session s) =>
    max(0, (DateTime.now().millisecondsSinceEpoch - s.startedAt) ~/ 1000);

typedef Reader = T Function<T>(ProviderListenable<T> provider);

/// Starts a sync in the background when an account is connected. Errors are
/// left to the next round.
void syncIfLoggedIn(Reader read) {
  final auth = read(authNotifierProvider).valueOrNull;
  if (auth?.status != AuthStatus.authenticated) return;
  read(syncServiceProvider).sync().ignore();
}

/// Stops timers running on other devices: their sessions end now, with the
/// time since they started, and the push tells those devices to stop.
Future<void> stopElsewhere(Reader read, Iterable<Session> sessions) async {
  final db = read(appDatabaseProvider);
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final s in sessions) {
    await db.sessionsDao.completeSessionWithDuration(
      s.id,
      now,
      max(0, (now - s.startedAt) ~/ 1000),
    );
  }
  syncIfLoggedIn(read);
}
