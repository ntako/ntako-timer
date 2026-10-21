import 'dart:async';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import '../settings/settings_notifier.dart';
import 'timer_state.dart';

part 'timer_notifier.g.dart';

const _uuid = Uuid();
const _ongoingNotificationId = 43;
const _sessionDurationNotificationId = 46;

/// Settings key holding the id of the session this device is tracking.
/// Synced sessions from other devices can be open too, so "any open session"
/// is not enough to know which one to resume after an app kill.
const _activeSessionKey = 'active_session_id';

@Riverpod(keepAlive: true)
class TimerNotifier extends _$TimerNotifier {
  Timer? _ticker;
  Timer? _breakTicker;
  bool _sessionDurationFired = false;

  @override
  TimerState build() {
    return TimerState.initial();
  }

  // ----------------------------------------------------------------
  // Public interface
  // ----------------------------------------------------------------

  /// Call this when the app comes back to the foreground.
  /// Recalculates elapsed time from the stored wall-clock anchor.
  void onAppResume() {
    if (state.status != TimerStatus.running) return;
    if (state.trackingStartTime == null) return;
    final elapsed =
        DateTime.now().difference(state.trackingStartTime!).inSeconds;
    state = state.copyWith(elapsedSeconds: elapsed);
    _startTicker();
  }

  Future<void> selectTask(String? id) async {
    if (state.status != TimerStatus.idle) return;
    if (id == null) {
      state = state.copyWith(clearCurrentTaskId: true);
      return;
    }
    state = state.copyWith(currentTaskId: id);
  }

  Future<void> start({String? taskId}) async {
    if (state.status == TimerStatus.running) return;

    _sessionDurationFired = false;

    final sessionId = _uuid.v4();
    final now = DateTime.now();
    final resolvedTaskId = taskId ?? state.currentTaskId;

    final db = ref.read(appDatabaseProvider);
    await db.sessionsDao.insertSession(
      SessionsCompanion(
        id: Value(sessionId),
        taskId: Value(resolvedTaskId),
        type: const Value('tracking'),
        startedAt: Value(now.millisecondsSinceEpoch),
        durationSeconds: const Value(0),
        createdAt: Value(now.millisecondsSinceEpoch),
      ),
    );
    await db.settingsDao.setValue(_activeSessionKey, sessionId);
    state = state.copyWith(
      status: TimerStatus.running,
      trackingStartTime: now,
      elapsedSeconds: 0,
      activeSessionId: sessionId,
      currentTaskId: resolvedTaskId,
      clearPauseBreak: true,
    );

    _startTicker();
    await _showOngoing();
  }

  void pause() {
    if (state.status != TimerStatus.running) return;
    _ticker?.cancel();
    NotificationService.cancel(_ongoingNotificationId);

    final settings = ref.read(settingsNotifierProvider).valueOrNull ??
        const AppSettings();
    final breakSec = settings.breakDurationMinutes * 60;

    state = state.copyWith(
      status: TimerStatus.paused,
      clearTrackingStartTime: true,
      pauseBreakRemainingSeconds: breakSec > 0 ? breakSec : 0,
    );

    if (breakSec > 0) {
      _breakTicker?.cancel();
      _breakTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining = state.pauseBreakRemainingSeconds;
        if (remaining <= 1) {
          _breakTicker?.cancel();
          _breakTicker = null;
          state = state.copyWith(clearPauseBreak: true);
          final vol = ref.read(settingsNotifierProvider).valueOrNull?.alarmVolume ?? 8;
          _showBreakEndNotification(vol > 0);
        } else {
          state = state.copyWith(
              pauseBreakRemainingSeconds: remaining - 1);
        }
      });
    }
  }

  Future<void> resume() async {
    if (state.status != TimerStatus.paused) return;
    _breakTicker?.cancel();
    _breakTicker = null;

    final startTime =
        DateTime.now().subtract(Duration(seconds: state.elapsedSeconds));
    state = state.copyWith(
      status: TimerStatus.running,
      trackingStartTime: startTime,
      clearPauseBreak: true,
    );
    _startTicker();
    await _showOngoing();
  }

  /// Called once at startup to restore a session interrupted by an app kill.
  /// If a dangling open session is found, the timer is resumed from startedAt.
  Future<void> recoverDanglingSession() async {
    if (state.status != TimerStatus.idle) return;

    final db = ref.read(appDatabaseProvider);
    final activeId = await db.settingsDao.getValue(_activeSessionKey);
    if (activeId == null) return;

    final dangling = await db.sessionsDao.getSessionById(activeId);
    if (dangling == null || dangling.endedAt != null) {
      await db.settingsDao.deleteValue(_activeSessionKey);
      return;
    }

    _sessionDurationFired = false;
    final startTime =
        DateTime.fromMillisecondsSinceEpoch(dangling.startedAt);
    final elapsed = DateTime.now().difference(startTime).inSeconds;

    state = state.copyWith(
      status: TimerStatus.running,
      trackingStartTime: startTime,
      elapsedSeconds: elapsed,
      activeSessionId: dangling.id,
      currentTaskId: dangling.taskId,
    );

    _startTicker();
    await _showOngoing();
  }

  Future<void> stop() async {
    _ticker?.cancel();
    _breakTicker?.cancel();
    _breakTicker = null;
    NotificationService.cancel(_ongoingNotificationId);

    if (state.activeSessionId != null) {
      final db = ref.read(appDatabaseProvider);
      await db.sessionsDao.completeSessionWithDuration(
        state.activeSessionId!,
        DateTime.now().millisecondsSinceEpoch,
        state.elapsedSeconds,
      );
      await db.settingsDao.deleteValue(_activeSessionKey);
    }

    state = TimerState.initial(currentTaskId: state.currentTaskId);
  }

  // ----------------------------------------------------------------
  // Internal
  // ----------------------------------------------------------------

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.trackingStartTime == null) return;
      final elapsed =
          DateTime.now().difference(state.trackingStartTime!).inSeconds;
      state = state.copyWith(elapsedSeconds: elapsed);

      final settings = ref.read(settingsNotifierProvider).valueOrNull ??
          const AppSettings();

      // One-shot session duration notification
      final sessionMin = settings.sessionDurationMinutes;
      if (sessionMin > 0 && !_sessionDurationFired &&
          elapsed >= sessionMin * 60) {
        _sessionDurationFired = true;
        _showSessionDurationNotification(sessionMin, settings.alarmVolume > 0);
      }
    });
  }

  Future<void> _showOngoing() async {
    await NotificationService.showOngoing(
      id: _ongoingNotificationId,
      title: 'Tracking in corso',
      body: 'Timer attivo',
    );
  }

  void _showSessionDurationNotification(int minutes, bool sound) {
    NotificationService.showAlert(
      id: _sessionDurationNotificationId,
      title: 'Sessione completata!',
      body: 'Hai lavorato per $minutes minuti. Prenditi una pausa.',
      sound: sound,
    );
    Future.delayed(const Duration(seconds: 30), () {
      NotificationService.cancel(_sessionDurationNotificationId);
    });
  }

  void _showBreakEndNotification(bool sound) {
    NotificationService.showAlert(
      id: 45,
      title: 'Pausa terminata!',
      body: 'Riprendi il lavoro.',
      sound: sound,
    );
    Future.delayed(const Duration(seconds: 15), () {
      NotificationService.cancel(45);
    });
  }
}
