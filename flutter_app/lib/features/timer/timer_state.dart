import 'package:flutter/foundation.dart';

enum TimerPhase { work, shortBreak, longBreak }

enum TimerStatus { idle, running, paused }

enum TimerMode { pomodoro, tracking }

@immutable
class TimerState {
  final TimerMode mode;
  final TimerStatus status;
  final TimerPhase phase;

  /// Countdown remaining — pomodoro mode only.
  final int remainingSeconds;

  /// Total phase duration — pomodoro mode only.
  final int totalSeconds;

  /// Count-up elapsed — tracking mode only.
  final int elapsedSeconds;

  /// Wall-clock end time for accurate countdown after app resume.
  final DateTime? targetEndTime;

  /// Wall-clock anchor for accurate count-up after app resume.
  /// Represents when tracking "would have started" accounting for pauses.
  final DateTime? trackingStartTime;

  final String? currentTaskId;

  /// Tracks completed work pomodoros to determine long-break trigger.
  final int completedPomodoros;

  /// UUID of the in-progress DB session row (null when idle).
  final String? activeSessionId;

  const TimerState({
    this.mode = TimerMode.pomodoro,
    required this.status,
    required this.phase,
    required this.remainingSeconds,
    required this.totalSeconds,
    this.elapsedSeconds = 0,
    this.targetEndTime,
    this.trackingStartTime,
    this.currentTaskId,
    this.completedPomodoros = 0,
    this.activeSessionId,
  });

  factory TimerState.initial({
    int workSeconds = 25 * 60,
    TimerMode mode = TimerMode.pomodoro,
    String? currentTaskId,
  }) =>
      TimerState(
        mode: mode,
        status: TimerStatus.idle,
        phase: TimerPhase.work,
        remainingSeconds: workSeconds,
        totalSeconds: workSeconds,
        elapsedSeconds: 0,
        completedPomodoros: 0,
        currentTaskId: currentTaskId,
      );

  double get progress =>
      totalSeconds > 0 ? (totalSeconds - remainingSeconds) / totalSeconds : 0;

  TimerState copyWith({
    TimerMode? mode,
    TimerStatus? status,
    TimerPhase? phase,
    int? remainingSeconds,
    int? totalSeconds,
    int? elapsedSeconds,
    DateTime? targetEndTime,
    bool clearTargetEndTime = false,
    DateTime? trackingStartTime,
    bool clearTrackingStartTime = false,
    String? currentTaskId,
    bool clearCurrentTaskId = false,
    int? completedPomodoros,
    String? activeSessionId,
    bool clearActiveSessionId = false,
  }) =>
      TimerState(
        mode: mode ?? this.mode,
        status: status ?? this.status,
        phase: phase ?? this.phase,
        remainingSeconds: remainingSeconds ?? this.remainingSeconds,
        totalSeconds: totalSeconds ?? this.totalSeconds,
        elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
        targetEndTime:
            clearTargetEndTime ? null : (targetEndTime ?? this.targetEndTime),
        trackingStartTime: clearTrackingStartTime
            ? null
            : (trackingStartTime ?? this.trackingStartTime),
        currentTaskId:
            clearCurrentTaskId ? null : (currentTaskId ?? this.currentTaskId),
        completedPomodoros: completedPomodoros ?? this.completedPomodoros,
        activeSessionId: clearActiveSessionId
            ? null
            : (activeSessionId ?? this.activeSessionId),
      );
}
