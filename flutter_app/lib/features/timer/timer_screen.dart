import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../tasks/tasks_notifier.dart';
import 'timer_notifier.dart';
import 'timer_state.dart';

class TimerScreen extends ConsumerWidget {
  const TimerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(timerNotifierProvider);
    final tasks = ref.watch(activeTasksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('NTAKO Timer'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ModeToggle(timer: timer),
              const SizedBox(height: 16),
              _PhaseLabel(timer: timer),
              const SizedBox(height: 32),
              _CircularTimer(state: timer),
              const SizedBox(height: 32),
              _TaskSelector(timer: timer, tasks: tasks),
              const SizedBox(height: 32),
              _Controls(timer: timer),
              const SizedBox(height: 16),
              if (timer.mode == TimerMode.pomodoro)
                _PomodoroCounter(completed: timer.completedPomodoros),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeToggle extends ConsumerWidget {
  final TimerState timer;

  const _ModeToggle({required this.timer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SegmentedButton<TimerMode>(
      segments: const [
        ButtonSegment(
          value: TimerMode.pomodoro,
          label: Text('Pomodoro'),
          icon: Icon(Icons.timer_outlined),
        ),
        ButtonSegment(
          value: TimerMode.tracking,
          label: Text('Tracking'),
          icon: Icon(Icons.play_circle_outline),
        ),
      ],
      selected: {timer.mode},
      onSelectionChanged: timer.status == TimerStatus.idle
          ? (modes) =>
              ref.read(timerNotifierProvider.notifier).setMode(modes.first)
          : null,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }
}

class _PhaseLabel extends StatelessWidget {
  final TimerState timer;

  const _PhaseLabel({required this.timer});

  @override
  Widget build(BuildContext context) {
    if (timer.mode == TimerMode.tracking) {
      final color = Colors.purple.shade700;
      return Chip(
        backgroundColor: color.withValues(alpha: 0.15),
        label: Text(
          'Tracking libero',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      );
    }

    final (label, color) = switch (timer.phase) {
      TimerPhase.work => ('Sessione Focus', Colors.red.shade700),
      TimerPhase.shortBreak => ('Pausa Breve', Colors.green.shade700),
      TimerPhase.longBreak => ('Pausa Lunga', Colors.blue.shade700),
    };

    return Chip(
      backgroundColor: color.withValues(alpha: 0.15),
      label: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }
}

class _CircularTimer extends StatelessWidget {
  final TimerState state;

  const _CircularTimer({required this.state});

  @override
  Widget build(BuildContext context) {
    final displaySeconds = state.mode == TimerMode.tracking
        ? state.elapsedSeconds
        : state.remainingSeconds;

    final hours = displaySeconds ~/ 3600;
    final minutes = (displaySeconds % 3600) ~/ 60;
    final seconds = displaySeconds % 60;

    final timeLabel = hours > 0
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    final progress = state.mode == TimerMode.tracking ? 0.0 : state.progress;
    final theme = Theme.of(context);

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                state.mode == TimerMode.tracking
                    ? Colors.purple.shade400
                    : theme.colorScheme.primary,
              ),
            ),
          ),
          Text(
            timeLabel,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: hours > 0 ? 2 : 4,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskSelector extends ConsumerWidget {
  final TimerState timer;
  final AsyncValue<List<Task>> tasks;

  const _TaskSelector({required this.timer, required this.tasks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allTasks = tasks.valueOrNull ?? [];
    final expectedType =
        timer.mode == TimerMode.tracking ? 'tracker' : 'pomodoro';
    final taskList = allTasks.where((t) => t.type == expectedType).toList();
    if (taskList.isEmpty) return const SizedBox.shrink();

    // If the currently selected task doesn't match the mode, treat as unset.
    final selectedId = taskList.any((t) => t.id == timer.currentTaskId)
        ? timer.currentTaskId
        : null;

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: selectedId,
        hint: const Text('Seleziona un task (opzionale)'),
        isExpanded: true,
        items: [
          const DropdownMenuItem(value: null, child: Text('Nessun task')),
          ...taskList.map(
            (t) => DropdownMenuItem(
              value: t.id,
              child: Row(
                children: [
                  Expanded(
                    child: Text(t.title, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  if (t.type == 'pomodoro')
                    Text(
                      '${t.pomodorosDone}/${t.pomodoroGoal} 🍅',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Icon(Icons.timelapse,
                        size: 14,
                        color: Theme.of(context).colorScheme.outline),
                ],
              ),
            ),
          ),
        ],
        onChanged: timer.status == TimerStatus.idle
            ? (id) => ref.read(timerNotifierProvider.notifier).selectTask(id)
            : null,
      ),
    );
  }
}

class _Controls extends ConsumerWidget {
  final TimerState timer;

  const _Controls({required this.timer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(timerNotifierProvider.notifier);

    // Tracking mode requires a task to be selected before starting
    final needsTask = timer.mode == TimerMode.tracking &&
        timer.status == TimerStatus.idle &&
        timer.currentTaskId == null;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (timer.status != TimerStatus.idle)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: OutlinedButton.icon(
                  onPressed: notifier.stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
            FilledButton.icon(
              onPressed: needsTask
                  ? null
                  : switch (timer.status) {
                      TimerStatus.idle => () => notifier.start(),
                      TimerStatus.running => notifier.pause,
                      TimerStatus.paused => notifier.resume,
                    },
              icon: Icon(switch (timer.status) {
                TimerStatus.idle || TimerStatus.paused => Icons.play_arrow,
                TimerStatus.running => Icons.pause,
              }),
              label: Text(switch (timer.status) {
                TimerStatus.idle => 'Inizia',
                TimerStatus.running => 'Pausa',
                TimerStatus.paused => 'Riprendi',
              }),
              style: FilledButton.styleFrom(
                minimumSize: const Size(140, 48),
              ),
            ),
          ],
        ),
        if (needsTask)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Seleziona un task per avviare il tracking',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
      ],
    );
  }
}

class _PomodoroCounter extends StatelessWidget {
  final int completed;

  const _PomodoroCounter({required this.completed});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final done =
            i < (completed % 4 == 0 && completed > 0 ? 4 : completed % 4);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            Icons.circle,
            size: 16,
            color: done
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        );
      }),
    );
  }
}
