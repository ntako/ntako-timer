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
              _ElapsedDisplay(state: timer),
              const SizedBox(height: 32),
              _TaskSelector(timer: timer, tasks: tasks),
              const SizedBox(height: 32),
              _Controls(timer: timer),
            ],
          ),
        ),
      ),
    );
  }
}

class _ElapsedDisplay extends StatelessWidget {
  final TimerState state;

  const _ElapsedDisplay({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.elapsedSeconds;
    final hours = s ~/ 3600;
    final minutes = (s % 3600) ~/ 60;
    final seconds = s % 60;

    final timeLabel = hours > 0
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    final theme = Theme.of(context);

    // Break countdown display
    final breakRemaining = state.pauseBreakRemainingSeconds;
    final showBreakCountdown =
        state.status == TimerStatus.paused && breakRemaining > 0;
    final breakMm = (breakRemaining ~/ 60).toString().padLeft(2, '0');
    final breakSs = (breakRemaining % 60).toString().padLeft(2, '0');

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: null,
              strokeWidth: state.status == TimerStatus.running ? 4 : 0,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(Colors.purple.shade400),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.status != TimerStatus.idle)
                Text(
                  'Tracking',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.purple.shade400,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              Text(
                timeLabel,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: hours > 0 ? 2 : 4,
                ),
              ),
              if (state.status == TimerStatus.paused) ...[
                const SizedBox(height: 8),
                if (showBreakCountdown) ...[
                  Text(
                    'Pausa',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.orange,
                    ),
                  ),
                  Text(
                    '$breakMm:$breakSs',
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ] else
                  Text(
                    'Pausa',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
              ],
            ],
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
    final taskList = tasks.valueOrNull ?? [];
    if (taskList.isEmpty) return const SizedBox.shrink();

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: taskList.any((t) => t.id == timer.currentTaskId)
            ? timer.currentTaskId
            : null,
        hint: const Text('Seleziona un task (opzionale)'),
        isExpanded: true,
        items: [
          const DropdownMenuItem(value: null, child: Text('Nessun task')),
          ...taskList.map(
            (t) => DropdownMenuItem(
              value: t.id,
              child: Text(t.title, overflow: TextOverflow.ellipsis),
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

    return Row(
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
          onPressed: switch (timer.status) {
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
    );
  }
}
