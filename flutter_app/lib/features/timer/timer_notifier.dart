import 'dart:async';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/providers.dart';
import '../../features/settings/settings_notifier.dart';
import 'timer_state.dart';

part 'timer_notifier.g.dart';

const _uuid = Uuid();
const _notificationId = 42;
const _ongoingNotificationId = 43;

@Riverpod(keepAlive: true)
class TimerNotifier extends _$TimerNotifier {
  Timer? _ticker;

  @override
  TimerState build() {
    return TimerState.initial(workSeconds: _workSeconds);
  }

  // ----------------------------------------------------------------
  // Duration helpers (read from settings, with defaults)
  // ----------------------------------------------------------------

  int get _workSeconds {
    final settings = ref.read(settingsNotifierProvider).valueOrNull;
    return (settings?.workMinutes ?? 25) * 60;
  }

  int _breakSeconds(TimerPhase phase) {
    final settings = ref.read(settingsNotifierProvider).valueOrNull;
    return switch (phase) {
      TimerPhase.work => _workSeconds,
      TimerPhase.shortBreak => (settings?.shortBreakMinutes ?? 5) * 60,
      TimerPhase.longBreak => (settings?.longBreakMinutes ?? 15) * 60,
    };
  }

  // ----------------------------------------------------------------
  // Public interface
  // ----------------------------------------------------------------

  /// Switch between Pomodoro and Tracking modes (only when idle).
  void setMode(TimerMode mode) {
    if (state.status != TimerStatus.idle) return;
    state = TimerState.initial(
      workSeconds: _workSeconds,
      mode: mode,
      currentTaskId: state.currentTaskId,
    );
  }

  /// Call this when the app comes back to the foreground.
  /// Recalculates time from the stored wall-clock anchor.
  void onAppResume() {
    if (state.status != TimerStatus.running) return;

    if (state.mode == TimerMode.tracking) {
      if (state.trackingStartTime == null) return;
      final elapsed =
          DateTime.now().difference(state.trackingStartTime!).inSeconds;
      state = state.copyWith(elapsedSeconds: elapsed);
      _startTicker();
    } else {
      if (state.targetEndTime == null) return;
      final remaining =
          state.targetEndTime!.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        _handleCompletion();
      } else {
        state = state.copyWith(remainingSeconds: remaining);
        _startTicker();
      }
    }
  }

  Future<void> selectTask(String? id) async {
    if (state.status != TimerStatus.idle) return;
    if (id == null) {
      state = state.copyWith(clearCurrentTaskId: true);
      return;
    }
    final task =
        await ref.read(appDatabaseProvider).tasksDao.getTaskById(id);
    final newMode =
        task?.type == 'tracker' ? TimerMode.tracking : TimerMode.pomodoro;
    state = state.copyWith(currentTaskId: id, mode: newMode);
  }

  Future<void> start({String? taskId}) async {
    if (state.status == TimerStatus.running) return;

    final sessionId = _uuid.v4();
    final now = DateTime.now();
    final resolvedTaskId = taskId ?? state.currentTaskId;

    // Determine effective mode from task type: tracker tasks always use
    // tracking mode regardless of the timer's current mode setting.
    TimerMode effectiveMode = state.mode;
    if (resolvedTaskId != null) {
      final task = await ref
          .read(appDatabaseProvider)
          .tasksDao
          .getTaskById(resolvedTaskId);
      if (task != null) {
        effectiveMode =
            task.type == 'tracker' ? TimerMode.tracking : TimerMode.pomodoro;
      }
    }

    if (effectiveMode == TimerMode.tracking) {
      await ref.read(appDatabaseProvider).sessionsDao.insertSession(
        SessionsCompanion(
          id: Value(sessionId),
          taskId: Value(resolvedTaskId),
          type: const Value('tracking'),
          startedAt: Value(now.millisecondsSinceEpoch),
          durationSeconds: const Value(0),
          createdAt: Value(now.millisecondsSinceEpoch),
        ),
      );
      state = state.copyWith(
        mode: effectiveMode,
        status: TimerStatus.running,
        trackingStartTime: now,
        elapsedSeconds: 0,
        activeSessionId: sessionId,
        currentTaskId: resolvedTaskId,
      );
    } else {
      final endTime = now.add(Duration(seconds: state.remainingSeconds));
      await ref.read(appDatabaseProvider).sessionsDao.insertSession(
        SessionsCompanion(
          id: Value(sessionId),
          taskId: Value(resolvedTaskId),
          type: Value(_phaseString(state.phase)),
          startedAt: Value(now.millisecondsSinceEpoch),
          durationSeconds: Value(state.totalSeconds),
          createdAt: Value(now.millisecondsSinceEpoch),
        ),
      );
      await NotificationService.scheduleTimerEnd(
        id: _notificationId,
        endTime: endTime,
        phase: state.phase,
      );
      state = state.copyWith(
        mode: effectiveMode,
        status: TimerStatus.running,
        targetEndTime: endTime,
        activeSessionId: sessionId,
        currentTaskId: resolvedTaskId,
      );
    }

    _startTicker();
    await _showOngoing();
  }

  void pause() {
    if (state.status != TimerStatus.running) return;
    _ticker?.cancel();
    NotificationService.cancel(_ongoingNotificationId);

    if (state.mode == TimerMode.tracking) {
      // elapsedSeconds already holds the latest value from the ticker
      state = state.copyWith(
        status: TimerStatus.paused,
        clearTrackingStartTime: true,
      );
    } else {
      NotificationService.cancel(_notificationId);
      state = state.copyWith(
        status: TimerStatus.paused,
        clearTargetEndTime: true,
      );
    }
  }

  Future<void> resume() async {
    if (state.status != TimerStatus.paused) return;

    if (state.mode == TimerMode.tracking) {
      // Shift start time so elapsed keeps accumulating correctly
      final startTime = DateTime.now()
          .subtract(Duration(seconds: state.elapsedSeconds));
      state = state.copyWith(
        status: TimerStatus.running,
        trackingStartTime: startTime,
      );
    } else {
      final endTime =
          DateTime.now().add(Duration(seconds: state.remainingSeconds));
      await NotificationService.scheduleTimerEnd(
        id: _notificationId,
        endTime: endTime,
        phase: state.phase,
      );
      state = state.copyWith(
        status: TimerStatus.running,
        targetEndTime: endTime,
      );
    }
    _startTicker();
    await _showOngoing();
  }

  Future<void> stop() async {
    _ticker?.cancel();
    NotificationService.cancel(_ongoingNotificationId);

    if (state.mode == TimerMode.tracking) {
      if (state.activeSessionId != null) {
        await ref.read(appDatabaseProvider).sessionsDao.completeSessionWithDuration(
          state.activeSessionId!,
          DateTime.now().millisecondsSinceEpoch,
          state.elapsedSeconds,
        );
      }
      // Preserve mode and task selection after stopping
      state = TimerState.initial(
        workSeconds: _workSeconds,
        mode: TimerMode.tracking,
        currentTaskId: state.currentTaskId,
      );
    } else {
      NotificationService.cancel(_notificationId);
      if (state.activeSessionId != null) {
        await ref.read(appDatabaseProvider).sessionsDao.completeSession(
          state.activeSessionId!,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      state = TimerState.initial(workSeconds: _workSeconds);
    }
  }

  // ----------------------------------------------------------------
  // Internal
  // ----------------------------------------------------------------

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.mode == TimerMode.tracking) {
        if (state.trackingStartTime == null) return;
        final elapsed =
            DateTime.now().difference(state.trackingStartTime!).inSeconds;
        state = state.copyWith(elapsedSeconds: elapsed);
      } else {
        if (state.targetEndTime == null) return;
        final remaining =
            state.targetEndTime!.difference(DateTime.now()).inSeconds;
        if (remaining <= 0) {
          _handleCompletion();
        } else {
          state = state.copyWith(remainingSeconds: remaining);
        }
      }
    });
  }

  Future<void> _handleCompletion() async {
    _ticker?.cancel();
    NotificationService.cancel(_notificationId);
    NotificationService.cancel(_ongoingNotificationId);

    final wasWork = state.phase == TimerPhase.work;
    final completed =
        wasWork ? state.completedPomodoros + 1 : state.completedPomodoros;

    if (state.activeSessionId != null) {
      final db = ref.read(appDatabaseProvider);
      final endMs = DateTime.now().millisecondsSinceEpoch;
      await db.sessionsDao.completeSession(state.activeSessionId!, endMs);

      if (wasWork && state.currentTaskId != null) {
        final task = await db.tasksDao.getTaskById(state.currentTaskId!);
        if (task != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          await db.tasksDao.updateTask(
            TasksCompanion(
              id: Value(task.id),
              pomodorosDone: Value(task.pomodorosDone + 1),
              updatedAt: Value(now),
              isSynced: const Value(false),
            ),
          );
        }
      }
    }

    final nextPhase = _nextPhase(state.phase, completed);
    final nextDuration = _breakSeconds(nextPhase);

    state = state.copyWith(
      status: TimerStatus.idle,
      phase: nextPhase,
      remainingSeconds: nextDuration,
      totalSeconds: nextDuration,
      completedPomodoros: completed,
      clearTargetEndTime: true,
      clearActiveSessionId: true,
    );
  }

  Future<void> _showOngoing() async {
    final s = state;
    final String title;
    final String body;

    if (s.mode == TimerMode.tracking) {
      title = 'Tracking in corso';
      body = 'Timer attivo';
    } else {
      title = switch (s.phase) {
        TimerPhase.work => 'Sessione focus',
        TimerPhase.shortBreak => 'Pausa breve',
        TimerPhase.longBreak => 'Pausa lunga',
      };
      if (s.targetEndTime != null) {
        final h = s.targetEndTime!.hour.toString().padLeft(2, '0');
        final m = s.targetEndTime!.minute.toString().padLeft(2, '0');
        body = 'Finisce alle $h:$m';
      } else {
        final min = s.remainingSeconds ~/ 60;
        final sec = s.remainingSeconds % 60;
        body = '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')} rimasti';
      }
    }

    await NotificationService.showOngoing(
      id: _ongoingNotificationId,
      title: title,
      body: body,
    );
  }

  TimerPhase _nextPhase(TimerPhase current, int completedPomodoros) {
    if (current != TimerPhase.work) return TimerPhase.work;
    final settings = ref.read(settingsNotifierProvider).valueOrNull;
    final longBreakEvery = settings?.pomodorosBeforeLongBreak ?? 4;
    return completedPomodoros % longBreakEvery == 0
        ? TimerPhase.longBreak
        : TimerPhase.shortBreak;
  }

  String _phaseString(TimerPhase phase) => switch (phase) {
    TimerPhase.work => 'work',
    TimerPhase.shortBreak => 'short_break',
    TimerPhase.longBreak => 'long_break',
  };
}
