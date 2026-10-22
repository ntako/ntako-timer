import 'package:flutter/foundation.dart';

enum TimerStatus { idle, running, paused }

@immutable
class TimerState {
  final TimerStatus status;

  /// Count-up elapsed seconds.
  final int elapsedSeconds;

  /// Wall-clock anchor for accurate count-up after app resume.
  /// Represents when tracking "would have started" accounting for pauses.
  final DateTime? trackingStartTime;

  final String? currentTaskId;

  /// UUID of the in-progress DB session row (null when idle).
  final String? activeSessionId;

  /// Remaining seconds in the break countdown (0 = no active countdown).
  final int pauseBreakRemainingSeconds;

  const TimerState({
    required this.status,
    this.elapsedSeconds = 0,
    this.trackingStartTime,
    this.currentTaskId,
    this.activeSessionId,
    this.pauseBreakRemainingSeconds = 0,
  });

  factory TimerState.initial({String? currentTaskId}) => TimerState(
    status: TimerStatus.idle,
    elapsedSeconds: 0,
    currentTaskId: currentTaskId,
    pauseBreakRemainingSeconds: 0,
  );

  TimerState copyWith({
    TimerStatus? status,
    int? elapsedSeconds,
    DateTime? trackingStartTime,
    bool clearTrackingStartTime = false,
    String? currentTaskId,
    bool clearCurrentTaskId = false,
    String? activeSessionId,
    bool clearActiveSessionId = false,
    int? pauseBreakRemainingSeconds,
    bool clearPauseBreak = false,
  }) => TimerState(
    status: status ?? this.status,
    elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    trackingStartTime: clearTrackingStartTime
        ? null
        : (trackingStartTime ?? this.trackingStartTime),
    currentTaskId: clearCurrentTaskId
        ? null
        : (currentTaskId ?? this.currentTaskId),
    activeSessionId: clearActiveSessionId
        ? null
        : (activeSessionId ?? this.activeSessionId),
    pauseBreakRemainingSeconds: clearPauseBreak
        ? 0
        : (pauseBreakRemainingSeconds ?? this.pauseBreakRemainingSeconds),
  );
}
