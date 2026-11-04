import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import 'history_report.dart';
import 'report_widgets.dart';

final _allSessionsProvider = StreamProvider<List<Session>>(
  (ref) => ref.watch(appDatabaseProvider).sessionsDao.watchAllSessions(),
);

final _allTasksProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(appDatabaseProvider).tasksDao.watchAllTasks(),
);

final _allCategoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(appDatabaseProvider).categoriesDao.watchAllCategories(),
);

/// Kept while the app runs, so leaving the tab doesn't reset the filters.
final historyFiltersProvider = StateProvider<HistoryFilters>(
  (ref) => const HistoryFilters(),
);

final _showChartsProvider = StateProvider<bool>((ref) => true);

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(_allSessionsProvider);
    final tasks = ref.watch(_allTasksProvider).valueOrNull ?? const [];
    final categories =
        ref.watch(_allCategoriesProvider).valueOrNull ?? const [];
    final filters = ref.watch(historyFiltersProvider);
    final showCharts = ref.watch(_showChartsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Storico'), centerTitle: true),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (sessions) {
          if (sessions.isEmpty) return const _EmptyState();

          final tasksById = {for (final t in tasks) t.id: t};
          final categoriesById = {for (final c in categories) c.id: c};
          final report = HistoryReport.build(
            sessions: sessions,
            tasks: tasksById,
            categories: categoriesById,
            filters: filters,
            now: DateTime.now(),
          );
          final running = sessions.where((s) => s.endedAt == null).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _FilterBar(
                filters: filters,
                tasks: tasks,
                categories: categories,
              ),
              const SizedBox(height: 4),
              Text(
                _rangeText(report),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              _Totals(report: report),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.bar_chart),
                    label: Text('Grafici'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.list),
                    label: Text('Lista'),
                  ),
                ],
                selected: {showCharts},
                onSelectionChanged: (v) =>
                    ref.read(_showChartsProvider.notifier).state = v.first,
              ),
              const SizedBox(height: 12),
              for (final s in running)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _SessionTile(
                    session: s,
                    task: tasksById[s.taskId],
                    isRunning: true,
                  ),
                ),
              if (report.sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'Nessuna sessione con questi filtri.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else if (showCharts) ...[
                ReportCard(
                  title: 'Ore per ${_groupWord(report.group)}, per categoria',
                  child: StackedHoursChart(
                    labels: report.bucketLabels,
                    series: report.categories,
                  ),
                ),
                ReportCard(
                  title: 'Per categoria',
                  child: BarList(
                    items: [
                      for (final c in [
                        ...report.categories,
                      ]..sort((a, b) => b.seconds.compareTo(a.seconds)))
                        BarItem(c.name, null, c.color, c.seconds),
                    ],
                  ),
                ),
                ReportCard(
                  title: 'Task principali',
                  child: BarList(
                    items: [
                      for (final t in report.tasks)
                        BarItem(
                          t.name,
                          t.category.isEmpty ? null : t.category,
                          t.color,
                          t.seconds,
                        ),
                    ],
                  ),
                ),
              ] else
                ..._sessionList(context, report, tasksById),
            ],
          );
        },
      ),
    );
  }

  static String _rangeText(HistoryReport r) {
    final last = DateTime(r.end.year, r.end.month, r.end.day - 1);
    final range = last == r.start
        ? formatDay(r.start)
        : '${formatDay(r.start)} – ${formatDay(last)}';
    return '$range · raggruppato per ${_groupWord(r.group)}';
  }

  static String _groupWord(HistoryGroup g) => switch (g) {
    HistoryGroup.week => 'settimana',
    HistoryGroup.month => 'mese',
    _ => 'giorno',
  };

  /// Sessions grouped by day, each day headed by its total.
  static List<Widget> _sessionList(
    BuildContext context,
    HistoryReport report,
    Map<String, Task> tasksById,
  ) {
    final byDay = <DateTime, List<Session>>{};
    for (final s in report.sessions) {
      final d = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      byDay.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(s);
    }
    final theme = Theme.of(context);
    return [
      for (final entry in byDay.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  DateFormat('EEEE d MMMM', 'it').format(entry.key),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                formatHours(
                  entry.value.fold(0, (sum, s) => sum + s.durationSeconds),
                ),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        for (final s in entry.value)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _SessionTile(session: s, task: tasksById[s.taskId]),
          ),
      ],
    ];
  }
}

// ── Filters ─────────────────────────────────────────────────────────────────

class _FilterBar extends ConsumerWidget {
  final HistoryFilters filters;
  final List<Task> tasks;
  final List<Category> categories;

  const _FilterBar({
    required this.filters,
    required this.tasks,
    required this.categories,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(historyFiltersProvider.notifier);
    void update(HistoryFilters f) => notifier.state = f;

    final categoryLabel = switch (filters.categoryId) {
      null => 'Tutte le categorie',
      noCategory => 'Senza categoria',
      final id => categories.where((c) => c.id == id).firstOrNull?.name ?? '?',
    };
    final taskLabel = filters.taskId == null
        ? 'Tutti i task'
        : tasks.where((t) => t.id == filters.taskId).firstOrNull?.title ?? '?';

    // Tasks offered: those of the chosen category, live ones first.
    final taskChoices =
        tasks.where((t) {
          if (filters.categoryId == null) return true;
          if (filters.categoryId == noCategory) return t.categoryId == null;
          return t.categoryId == filters.categoryId;
        }).toList()..sort((a, b) {
          final deleted =
              (a.deletedAt != null ? 1 : 0) - (b.deletedAt != null ? 1 : 0);
          return deleted != 0
              ? deleted
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        PeriodChip(filters: filters, onChanged: update),
        FilterChipButton(
          icon: Icons.label_outline,
          label: categoryLabel,
          active: filters.categoryId != null,
          onTap: () async {
            final picked = await pickOption<String?>(context, 'Categoria', [
              const PickOption(null, 'Tutte le categorie'),
              const PickOption(noCategory, 'Senza categoria'),
              for (final c
                  in [...categories]..sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  ))
                PickOption(
                  c.id,
                  c.deletedAt != null ? '${c.name} (eliminata)' : c.name,
                ),
            ], filters.categoryId);
            if (picked == null) return;
            // A task from another category would match nothing.
            update(
              filters.copyWith(
                categoryId: () => picked.value,
                taskId: () => null,
              ),
            );
          },
        ),
        FilterChipButton(
          icon: Icons.checklist,
          label: taskLabel,
          active: filters.taskId != null,
          onTap: () async {
            final picked = await pickOption<String?>(context, 'Task', [
              const PickOption(null, 'Tutti i task'),
              for (final t in taskChoices)
                PickOption(
                  t.id,
                  '${t.title.isEmpty ? '(senza titolo)' : t.title}'
                  '${t.deletedAt != null ? ' (eliminato)' : ''}',
                ),
            ], filters.taskId);
            if (picked != null) {
              update(filters.copyWith(taskId: () => picked.value));
            }
          },
        ),
        GroupChip(filters: filters, onChanged: update),
      ],
    );
  }
}

// ── Totals ──────────────────────────────────────────────────────────────────

class _Totals extends StatelessWidget {
  final HistoryReport report;

  const _Totals({required this.report});

  @override
  Widget build(BuildContext context) {
    final avg = report.activeDays == 0
        ? '—'
        : formatHours(report.totalSeconds ~/ report.activeDays);
    return Row(
      children: [
        ReportStat('Tempo', formatHours(report.totalSeconds)),
        ReportStat('Sessioni', '${report.sessions.length}'),
        ReportStat('Giorni attivi', '${report.activeDays}'),
        ReportStat('Media/giorno', avg),
      ],
    );
  }
}

class _EmptyState extends ConsumerStatefulWidget {
  const _EmptyState();

  @override
  ConsumerState<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends ConsumerState<_EmptyState> {
  bool _syncing = false;
  String? _error;

  Future<void> _doSync() async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await ref.read(syncServiceProvider).sync();
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 401) {
        // Token scaduto o non valido — esegui logout e mostra messaggio
        await ref.read(authNotifierProvider.notifier).logout();
        setState(
          () => _error = 'Sessione scaduta. Effettua nuovamente il login.',
        );
      } else {
        setState(() => _error = 'Errore di rete: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Errore: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn =
        ref.watch(authNotifierProvider).valueOrNull?.status ==
        AuthStatus.authenticated;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.history, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Nessuna sessione trovata.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          if (isLoggedIn) ...[
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            FilledButton.icon(
              onPressed: _syncing ? null : _doSync,
              icon: _syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync),
              label: Text(_syncing ? 'Sincronizzazione…' : 'Sincronizza ora'),
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'Accedi per importare le sessioni dal cloud.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;
  final Task? task;
  final bool isRunning;

  const _SessionTile({
    required this.session,
    this.task,
    this.isRunning = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = _typeInfo(session.type);
    final duration = _formatDuration(session.durationSeconds);
    final date = _formatDate(session.startedAt);

    return Opacity(
      opacity: isRunning ? 0.6 : 1.0,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _TypeBadge(label: label, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task?.title ?? '—',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isRunning ? '$date  •  in corso' : date,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isRunning ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ],
                ),
              ),
              isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      duration,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  (String, Color) _typeInfo(String type) => switch (type) {
    'tracking' => ('T', Colors.purple.shade600),
    _ => ('T', Colors.purple.shade600),
  };

  /// Same "1h 02m" / "13m" as the totals; seconds only under a minute.
  String _formatDuration(int totalSeconds) =>
      totalSeconds < 60 ? '${totalSeconds}s' : formatHours(totalSeconds);

  String _formatDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(dt.year, dt.month, dt.day);

    final time = DateFormat('HH:mm').format(dt);
    if (day == today) return 'Oggi $time';
    if (day == yesterday) return 'Ieri $time';
    return DateFormat('dd/MM HH:mm').format(dt);
  }
}

class _TypeBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _TypeBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
