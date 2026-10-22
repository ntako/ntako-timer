import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import 'history_report.dart';

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
                _Card(
                  title: 'Ore per ${_groupWord(report.group)}, per categoria',
                  child: _TimeChart(report: report),
                ),
                _Card(
                  title: 'Per categoria',
                  child: _BarList(
                    items: [
                      for (final c in [
                        ...report.categories,
                      ]..sort((a, b) => b.seconds.compareTo(a.seconds)))
                        _BarItem(c.name, null, c.color, c.seconds),
                    ],
                  ),
                ),
                _Card(
                  title: 'Task principali',
                  child: _BarList(
                    items: [
                      for (final t in report.tasks)
                        _BarItem(
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

class _Option<T> {
  final T value;
  final String label;
  const _Option(this.value, this.label);
}

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
    final periodLabel =
        filters.period == HistoryPeriod.custom &&
            filters.customFrom != null &&
            filters.customTo != null
        ? '${DateFormat('d/M/yy').format(filters.customFrom!)} – '
              '${DateFormat('d/M/yy').format(filters.customTo!)}'
        : filters.period.label;

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
        _FilterChip(
          icon: Icons.date_range,
          label: periodLabel,
          onTap: () async {
            final picked = await _pick(context, 'Periodo', [
              for (final p in HistoryPeriod.values) _Option(p, p.label),
            ], filters.period);
            if (picked == null || !context.mounted) return;
            if (picked.value != HistoryPeriod.custom) {
              update(filters.copyWith(period: picked.value));
              return;
            }
            final now = DateTime.now();
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime(now.year + 1, 12, 31),
              initialDateRange:
                  filters.customFrom != null && filters.customTo != null
                  ? DateTimeRange(
                      start: filters.customFrom!,
                      end: filters.customTo!,
                    )
                  : DateTimeRange(
                      start: DateTime(now.year, now.month),
                      end: now,
                    ),
              locale: const Locale('it'),
            );
            if (range == null) return;
            update(
              filters.copyWith(
                period: HistoryPeriod.custom,
                customFrom: range.start,
                customTo: range.end,
              ),
            );
          },
        ),
        _FilterChip(
          icon: Icons.label_outline,
          label: categoryLabel,
          active: filters.categoryId != null,
          onTap: () async {
            final picked = await _pick<String?>(context, 'Categoria', [
              const _Option(null, 'Tutte le categorie'),
              const _Option(noCategory, 'Senza categoria'),
              for (final c
                  in [...categories]..sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  ))
                _Option(
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
        _FilterChip(
          icon: Icons.checklist,
          label: taskLabel,
          active: filters.taskId != null,
          onTap: () async {
            final picked = await _pick<String?>(context, 'Task', [
              const _Option(null, 'Tutti i task'),
              for (final t in taskChoices)
                _Option(
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
        _FilterChip(
          icon: Icons.view_week_outlined,
          label: filters.group == HistoryGroup.auto
              ? 'Raggruppa: auto'
              : 'Per ${filters.group.label.toLowerCase()}',
          active: filters.group != HistoryGroup.auto,
          onTap: () async {
            final picked = await _pick(context, 'Raggruppa per', [
              for (final g in HistoryGroup.values) _Option(g, g.label),
            ], filters.group);
            if (picked != null) update(filters.copyWith(group: picked.value));
          },
        ),
      ],
    );
  }

  /// Bottom sheet with one row per option; null when dismissed.
  static Future<_Option<T>?> _pick<T>(
    BuildContext context,
    String title,
    List<_Option<T>> options,
    T current,
  ) => showModalBottomSheet<_Option<T>>(
    context: context,
    // Above the shell's bottom navigation bar, which would cover the end.
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final o in options)
            ListTile(
              title: Text(o.label),
              trailing: o.value == current ? const Icon(Icons.check) : null,
              selected: o.value == current,
              onTap: () => Navigator.of(context).pop(o),
            ),
        ],
      ),
    ),
  );
}

class _FilterChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 18),
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(label, overflow: TextOverflow.ellipsis),
    ),
    side: active
        ? BorderSide(color: Theme.of(context).colorScheme.primary)
        : null,
    onPressed: onTap,
  );
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
        _Stat('Tempo', formatHours(report.totalSeconds)),
        _Stat('Sessioni', '${report.sessions.length}'),
        _Stat('Giorni attivi', '${report.activeDays}'),
        _Stat('Media/giorno', avg),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Charts ──────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final String title;
  final Widget child;

  const _Card({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

/// Hours per bucket, stacked by category. Each category keeps its own color
/// (its identity in the app); the legend and the list view carry the names
/// and values too, so nothing depends on color alone.
class _TimeChart extends StatelessWidget {
  final HistoryReport report;

  const _TimeChart({required this.report});

  static const _height = 220.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = report.categories;
    final n = report.bucketLabels.length;
    final totals = List.generate(
      n,
      (i) => cats.fold(0, (sum, c) => sum + c.buckets[i]),
    );
    final maxHours = totals.fold(0, (a, b) => a > b ? a : b) / 3600;
    final maxY = maxHours <= 0 ? 1.0 : (maxHours * 1.1).ceilToDouble();
    final surface =
        theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;
    final ink = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cats.length > 1) ...[
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final c in cats)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(c.name, style: theme.textTheme.bodySmall),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final plotWidth = constraints.maxWidth - 36;
            final barWidth = (plotWidth / n * 0.6).clamp(2.0, 18.0);
            // 2px of surface between stacked segments, in data units.
            final gap = maxY * 2 / (_height - 28);
            final labelEvery = (n / (plotWidth / 44)).ceil().clamp(1, n);

            return SizedBox(
              height: _height,
              child: BarChart(
                BarChartData(
                  maxY: maxY,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        getTitlesWidget: (value, meta) =>
                            value == value.roundToDouble()
                            ? SideTitleWidget(
                                meta: meta,
                                child: Text(
                                  '${value.toInt()} h',
                                  style: TextStyle(fontSize: 10, color: ink),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i % labelEvery != 0) {
                            return const SizedBox.shrink();
                          }
                          return SideTitleWidget(
                            meta: meta,
                            child: Text(
                              report.bucketLabels[i],
                              style: TextStyle(fontSize: 10, color: ink),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final i = group.x;
                        if (totals[i] == 0) return null;
                        final style = TextStyle(
                          color: theme.colorScheme.onInverseSurface,
                          fontSize: 12,
                        );
                        final rows = [
                          for (final c in cats)
                            if (c.buckets[i] > 0) c,
                        ]..sort((a, b) => b.buckets[i].compareTo(a.buckets[i]));
                        return BarTooltipItem(
                          '${report.bucketLabels[i]} · ${formatHours(totals[i])}',
                          style.copyWith(fontWeight: FontWeight.w700),
                          textAlign: TextAlign.left,
                          children: [
                            if (rows.length > 1)
                              for (final c in rows)
                                TextSpan(
                                  text:
                                      '\n${formatHours(c.buckets[i])}  ${c.name}',
                                  style: style,
                                ),
                          ],
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < n; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: totals[i] / 3600,
                            width: barWidth,
                            color: Colors.transparent,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                            rodStackItems: _stack(cats, i, gap, surface),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  static List<BarChartRodStackItem> _stack(
    List<CategorySeries> cats,
    int i,
    double gap,
    Color surface,
  ) {
    final items = <BarChartRodStackItem>[];
    var y = 0.0;
    for (final c in cats) {
      final h = c.buckets[i] / 3600;
      if (h <= 0) continue;
      final from = items.isEmpty ? y : (y + gap).clamp(y, y + h);
      items.add(BarChartRodStackItem(from, y + h, c.color));
      y += h;
    }
    return items;
  }
}

class _BarItem {
  final String name;
  final String? subtitle;
  final Color color;
  final int seconds;

  const _BarItem(this.name, this.subtitle, this.color, this.seconds);
}

/// Horizontal bars: name, bar, value at the tip.
class _BarList extends StatelessWidget {
  final List<_BarItem> items;

  const _BarList({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = items.fold(1, (m, i) => i.seconds > m ? i.seconds : m);
    return Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (item.subtitle != null)
                        Text(
                          item.subtitle!,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (item.seconds / max).clamp(0.01, 1.0),
                      child: Container(
                        height: 14,
                        decoration: BoxDecoration(
                          color: item.color,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: Text(
                    formatHours(item.seconds),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
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
