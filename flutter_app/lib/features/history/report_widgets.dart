import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'history_report.dart';

/// Building blocks shared by the reports (task history, presences).

// ── Filters ─────────────────────────────────────────────────────────────────

class PickOption<T> {
  final T value;
  final String label;
  const PickOption(this.value, this.label);
}

/// Bottom sheet with one row per option; null when dismissed.
Future<PickOption<T>?> pickOption<T>(
  BuildContext context,
  String title,
  List<PickOption<T>> options,
  T current,
) => showModalBottomSheet<PickOption<T>>(
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

/// Period of a report; "custom" asks for the dates.
class PeriodChip extends StatelessWidget {
  final HistoryFilters filters;
  final ValueChanged<HistoryFilters> onChanged;

  const PeriodChip({super.key, required this.filters, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    void update(HistoryFilters f) => onChanged(f);
    final periodLabel =
        filters.period == HistoryPeriod.custom &&
            filters.customFrom != null &&
            filters.customTo != null
        ? '${DateFormat('d/M/yy').format(filters.customFrom!)} – '
              '${DateFormat('d/M/yy').format(filters.customTo!)}'
        : filters.period.label;
    return FilterChipButton(
      icon: Icons.date_range,
      label: periodLabel,
      onTap: () async {
        final picked = await pickOption(context, 'Periodo', [
          for (final p in HistoryPeriod.values) PickOption(p, p.label),
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
              : DateTimeRange(start: DateTime(now.year, now.month), end: now),
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
    );
  }
}

class GroupChip extends StatelessWidget {
  final HistoryFilters filters;
  final ValueChanged<HistoryFilters> onChanged;

  const GroupChip({super.key, required this.filters, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    void update(HistoryFilters f) => onChanged(f);
    return FilterChipButton(
      icon: Icons.view_week_outlined,
      label: filters.group == HistoryGroup.auto
          ? 'Raggruppa: auto'
          : 'Per ${filters.group.label.toLowerCase()}',
      active: filters.group != HistoryGroup.auto,
      onTap: () async {
        final picked = await pickOption(context, 'Raggruppa per', [
          for (final g in HistoryGroup.values) PickOption(g, g.label),
        ], filters.group);
        if (picked != null) update(filters.copyWith(group: picked.value));
      },
    );
  }
}

class FilterChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const FilterChipButton({
    super.key,
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

class ReportStat extends StatelessWidget {
  final String label;
  final String value;

  const ReportStat(this.label, this.value, {super.key});

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

class ReportCard extends StatelessWidget {
  final String title;
  final Widget child;

  const ReportCard({super.key, required this.title, required this.child});

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

/// Hours per bucket, stacked by series (categories, places). Each series
/// keeps its own color (its identity in the app); the legend and the list
/// view carry the names and values too, so nothing depends on color alone.
class StackedHoursChart extends StatelessWidget {
  final List<String> labels;
  final List<CategorySeries> series;

  const StackedHoursChart({
    super.key,
    required this.labels,
    required this.series,
  });

  static const _height = 220.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = series;
    final n = labels.length;
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
                              labels[i],
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
                          '${labels[i]} · ${formatHours(totals[i])}',
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

class BarItem {
  final String name;
  final String? subtitle;
  final Color color;
  final int seconds;

  const BarItem(this.name, this.subtitle, this.color, this.seconds);
}

/// Horizontal bars: name, bar, value at the tip.
class BarList extends StatelessWidget {
  final List<BarItem> items;

  const BarList({super.key, required this.items});

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
