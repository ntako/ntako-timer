import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../categories/categories_notifier.dart';
import '../tasks/tasks_notifier.dart';
import '../voice/voice_command_button.dart';
import 'remote_sessions.dart';
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
        actions: const [VoiceCommandButton()],
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
              const SizedBox(height: 24),
              const _RemoteTimers(),
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
    // Titles can repeat across categories: show the category too.
    final categoryNames = {
      for (final c in ref.watch(activeCategoriesProvider).valueOrNull ?? [])
        c.id: c.name,
    };
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

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
              child: Text.rich(
                TextSpan(
                  text: t.title,
                  children: [
                    if (categoryNames[t.categoryId] case final category?)
                      TextSpan(
                        text: '  ·  $category',
                        style: TextStyle(color: muted),
                      ),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
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
            TimerStatus.idle => () => _start(context, ref),
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
          style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
        ),
      ],
    );
  }
}

/// Starts the timer; if another device is already timing, asks whether to
/// stop that one first or run both.
Future<void> _start(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(timerNotifierProvider.notifier);
  final remote = ref.read(remoteRunningProvider);
  if (remote.isEmpty) {
    await notifier.start();
    return;
  }
  final titles = ref.read(taskTitlesProvider).valueOrNull ?? const {};
  final lines = [
    for (final s in remote)
      '• ${titles[s.taskId] ?? 'Senza task'} · in corso da ${clock(remoteElapsed(s))}',
  ].join('\n');
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('C\'è già un timer in corso'),
      content: Text('Su un altro dispositivo:\n$lines'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'both'),
          child: const Text('Avvia comunque'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'replace'),
          child: const Text('Ferma l\'altro e avvia'),
        ),
      ],
    ),
  );
  if (choice == null) return;
  if (choice == 'replace') await stopElsewhere(ref.read, remote);
  await notifier.start();
}

/// Timers running on other devices, with their time and a stop button.
class _RemoteTimers extends ConsumerStatefulWidget {
  const _RemoteTimers();

  @override
  ConsumerState<_RemoteTimers> createState() => _RemoteTimersState();
}

class _RemoteTimersState extends ConsumerState<_RemoteTimers> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(remoteRunningProvider).isNotEmpty) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _stop(Session s, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fermare il timer?'),
        content: Text(
          '«$title» è in corso su un altro dispositivo. La sessione viene '
          'salvata con il tempo dall\'inizio, e quel dispositivo si ferma '
          'alla prossima sincronizzazione.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ferma'),
          ),
        ],
      ),
    );
    if (ok == true) await stopElsewhere(ref.read, [s]);
  }

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteRunningProvider);
    if (remote.isEmpty) return const SizedBox.shrink();
    final titles = ref.watch(taskTitlesProvider).valueOrNull ?? const {};
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.devices,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'In corso su un altro dispositivo',
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            for (final s in remote)
              ListTile(
                title: Text(
                  titles[s.taskId] ?? 'Senza task',
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'Iniziato alle ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(s.startedAt)).format(context)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      clock(remoteElapsed(s)),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          _stop(s, titles[s.taskId] ?? 'Senza task'),
                      child: const Text('Ferma'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
