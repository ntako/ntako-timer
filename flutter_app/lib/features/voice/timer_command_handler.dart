import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../core/messenger.dart';
import '../../core/providers.dart';
import '../history/history_report.dart';
import '../timer/remote_sessions.dart';
import '../timer/timer_notifier.dart';
import '../timer/timer_state.dart';
import 'timer_commands.dart';

final timerCommandHandlerProvider = Provider<TimerCommandHandler>(
  (ref) => TimerCommandHandler(ref),
);

/// Runs [TimerCommand]s on the timer and returns what happened, in a
/// sentence fit for a snackbar.
class TimerCommandHandler {
  final Ref _ref;

  TimerCommandHandler(this._ref);

  Future<String> run(TimerCommand command) async {
    final timer = _ref.read(timerNotifierProvider.notifier);
    final state = _ref.read(timerNotifierProvider);

    switch (command.action) {
      case TimerCommandAction.start:
        if (state.status == TimerStatus.running) {
          return 'Il timer è già in corso';
        }
        // "Avvia" on a paused session continues it rather than opening a
        // second, overlapping one.
        if (state.status == TimerStatus.paused) {
          await timer.resume();
          return 'Timer ripreso';
        }
        final db = _ref.read(appDatabaseProvider);
        final tasks = await db.select(db.tasks).get();
        final categoryNames = {
          for (final c in await db.select(db.categories).get())
            if (c.deletedAt == null) c.id: c.name,
        };
        Task? task;
        if (command.task != null) {
          final match = matchTask(
            tasks,
            command.task!,
            categoryNames: categoryNames,
          );
          if (match.ambiguous.isNotEmpty) {
            final names = match.ambiguous
                .take(3)
                .map((t) => taskLabel(t, categoryNames))
                .join(', ');
            return 'Più task corrispondono a «${command.task}»: $names. '
                'Di\' anche la categoria, ad esempio «avvia sviluppo arundo».';
          }
          if (match.task == null) {
            return 'Nessun task aperto si chiama «${command.task}»: timer non avviato';
          }
          task = match.task;
        } else {
          // "Avvia" alone: the task selected on the timer screen, if any.
          task = tasks.where((t) => t.id == state.currentTaskId).firstOrNull;
        }
        // No dialog possible here (voice, links): start, and offer to stop
        // timers running elsewhere from the confirmation message.
        _runningElsewhere = await db.sessionsDao.getOpenSessions();
        await timer.start(taskId: task?.id);
        final started = task == null
            ? 'Timer avviato senza task'
            : 'Timer avviato su ${taskLabel(task, categoryNames)}';
        return _runningElsewhere.isEmpty
            ? started
            : '$started. C\'è anche un timer su un altro dispositivo.';

      case TimerCommandAction.pause:
        if (state.status != TimerStatus.running) {
          return 'Il timer non è in corso';
        }
        timer.pause();
        return 'Timer in pausa';

      case TimerCommandAction.resume:
        if (state.status != TimerStatus.paused) {
          return state.status == TimerStatus.running
              ? 'Il timer è già in corso'
              : 'Nessun timer in pausa';
        }
        await timer.resume();
        return 'Timer ripreso';

      case TimerCommandAction.stop:
        if (state.status == TimerStatus.idle) return 'Il timer è già fermo';
        final elapsed = state.elapsedSeconds;
        await timer.stop();
        return 'Sessione salvata: '
            '${elapsed < 60 ? '$elapsed secondi' : formatHours(elapsed)}';
    }
  }

  /// Open sessions found by the last start, for the "Ferma l'altro" action.
  List<Session> _runningElsewhere = const [];

  /// Runs a command and shows the outcome.
  Future<void> runAndShow(TimerCommand command) async {
    try {
      _runningElsewhere = const [];
      final message = await run(command);
      final others = _runningElsewhere;
      showRootMessage(
        message,
        action: others.isEmpty
            ? null
            : SnackBarAction(
                label: 'Ferma l\'altro',
                onPressed: () => stopElsewhere(_ref.read, others),
              ),
      );
    } catch (e) {
      debugPrint('[TimerCommand] $command failed: $e');
      showRootMessage('Comando non riuscito: $e');
    }
  }

  /// Listens for `ntako://timer/…` links: launcher shortcuts, Siri and
  /// Google Assistant all open one. The stream also delivers the link the
  /// app was launched with. Call once the timer has recovered its state.
  StreamSubscription<Uri> listenToLinks() =>
      AppLinks().uriLinkStream.listen((uri) {
        final command = TimerCommand.fromUri(uri);
        if (command != null) runAndShow(command);
      });
}
