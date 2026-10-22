import 'package:flutter/painting.dart';
import '../../core/database/app_database.dart';

/// Filtered time report for the history screen.
///
/// Same periods and grouping rules as the admin panel
/// (backend/admin/report.php), so app and panel show the same numbers.
/// Sessions count on the day they started, in the device's timezone.

enum HistoryPeriod {
  today('Oggi'),
  yesterday('Ieri'),
  week('Questa settimana'),
  lastWeek('Settimana scorsa'),
  month('Questo mese'),
  lastMonth('Mese scorso'),
  year("Quest'anno"),
  lastYear('Anno scorso'),
  all('Tutto'),
  custom('Personalizzato');

  final String label;
  const HistoryPeriod(this.label);
}

enum HistoryGroup {
  auto('Automatico'),
  day('Giorno'),
  week('Settimana'),
  month('Mese');

  final String label;
  const HistoryGroup(this.label);
}

const _months = [
  'gen',
  'feb',
  'mar',
  'apr',
  'mag',
  'giu',
  'lug',
  'ago',
  'set',
  'ott',
  'nov',
  'dic',
];

/// Color for "Senza categoria", "Altri task" and invalid stored colors.
const neutralColor = Color(0xFF9CA3AF);

/// Category filter value meaning "sessions whose task has no category".
const noCategory = '__none__';

class HistoryFilters {
  final HistoryPeriod period;

  /// First and last day (inclusive) when [period] is custom.
  final DateTime? customFrom;
  final DateTime? customTo;

  /// null = all categories; [noCategory] = uncategorised; else a category id.
  final String? categoryId;

  /// null = all tasks.
  final String? taskId;
  final HistoryGroup group;

  const HistoryFilters({
    this.period = HistoryPeriod.month,
    this.customFrom,
    this.customTo,
    this.categoryId,
    this.taskId,
    this.group = HistoryGroup.auto,
  });

  HistoryFilters copyWith({
    HistoryPeriod? period,
    DateTime? customFrom,
    DateTime? customTo,
    String? Function()? categoryId,
    String? Function()? taskId,
    HistoryGroup? group,
  }) => HistoryFilters(
    period: period ?? this.period,
    customFrom: customFrom ?? this.customFrom,
    customTo: customTo ?? this.customTo,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    taskId: taskId != null ? taskId() : this.taskId,
    group: group ?? this.group,
  );

  /// [start, end) of the period. [firstSession] is used by "all".
  (DateTime, DateTime) range(DateTime now, {DateTime? firstSession}) {
    final today = DateTime(now.year, now.month, now.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
    return switch (period) {
      HistoryPeriod.today => (today, addDays(today, 1)),
      HistoryPeriod.yesterday => (addDays(today, -1), today),
      HistoryPeriod.week => (monday, addDays(monday, 7)),
      HistoryPeriod.lastWeek => (addDays(monday, -7), monday),
      HistoryPeriod.month => (
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1),
      ),
      HistoryPeriod.lastMonth => (
        DateTime(now.year, now.month - 1),
        DateTime(now.year, now.month),
      ),
      HistoryPeriod.year => (DateTime(now.year), DateTime(now.year + 1)),
      HistoryPeriod.lastYear => (DateTime(now.year - 1), DateTime(now.year)),
      HistoryPeriod.all => (
        firstSession == null
            ? today
            : DateTime(firstSession.year, firstSession.month, firstSession.day),
        addDays(today, 1),
      ),
      HistoryPeriod.custom => (
        _day(customFrom ?? DateTime(now.year, now.month)),
        addDays(_day(customTo ?? today), 1),
      ),
    };
  }

  /// [group], with "auto" resolved from the length of the range.
  HistoryGroup effectiveGroup(DateTime start, DateTime end) {
    if (group != HistoryGroup.auto) return group;
    final days = end.difference(start).inHours ~/ 24;
    if (days <= 45) return HistoryGroup.day;
    if (days <= 190) return HistoryGroup.week;
    return HistoryGroup.month;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
}

class CategorySeries {
  final String name;
  final Color color;
  final int seconds;

  /// Seconds per bucket, aligned with [HistoryReport.bucketLabels].
  final List<int> buckets;

  const CategorySeries(this.name, this.color, this.seconds, this.buckets);
}

class TaskTotal {
  final String name;
  final String category;
  final Color color;
  final int seconds;

  const TaskTotal(this.name, this.category, this.color, this.seconds);
}

class HistoryReport {
  final DateTime start;
  final DateTime end;
  final HistoryGroup group;
  final List<String> bucketLabels;

  /// Sorted by name: a category keeps its place (and color) whatever the
  /// filter.
  final List<CategorySeries> categories;

  /// Top 10 by time; the rest folded into one "Altri N task" entry.
  final List<TaskTotal> tasks;

  /// Finished sessions in range matching the filters, newest first.
  final List<Session> sessions;
  final int totalSeconds;
  final int activeDays;

  const HistoryReport({
    required this.start,
    required this.end,
    required this.group,
    required this.bucketLabels,
    required this.categories,
    required this.tasks,
    required this.sessions,
    required this.totalSeconds,
    required this.activeDays,
  });

  static HistoryReport build({
    required List<Session> sessions,
    required Map<String, Task> tasks,
    required Map<String, Category> categories,
    required HistoryFilters filters,
    required DateTime now,
  }) {
    final finished = sessions.where((s) => s.endedAt != null).toList();
    final first = finished.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            finished.map((s) => s.startedAt).reduce((a, b) => a < b ? a : b),
          );
    final (start, end) = filters.range(now, firstSession: first);
    final group = filters.effectiveGroup(start, end);

    // Every bucket of the range, empty ones included, in order.
    final bucketIndex = <String, int>{};
    final labels = <String>[];
    for (
      var d = start;
      d.isBefore(end);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final (key, label) = _bucket(d, group);
      if (!bucketIndex.containsKey(key)) {
        bucketIndex[key] = labels.length;
        labels.add(label);
      }
    }

    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final matching = finished.where((s) {
      if (s.startedAt < startMs || s.startedAt >= endMs) return false;
      final task = tasks[s.taskId];
      if (filters.taskId != null && s.taskId != filters.taskId) return false;
      if (filters.categoryId == noCategory) return task?.categoryId == null;
      if (filters.categoryId != null) {
        return task?.categoryId == filters.categoryId;
      }
      return true;
    }).toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    final catSeconds = <String, int>{};
    final catBuckets = <String, List<int>>{};
    final taskSeconds = <String, int>{};
    final days = <String>{};
    var total = 0;
    for (final s in matching) {
      final started = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      final catKey = tasks[s.taskId]?.categoryId ?? noCategory;
      final i = bucketIndex[_bucket(started, group).$1];
      catSeconds[catKey] = (catSeconds[catKey] ?? 0) + s.durationSeconds;
      final buckets = catBuckets.putIfAbsent(
        catKey,
        () => List.filled(labels.length, 0),
      );
      if (i != null) buckets[i] += s.durationSeconds;
      final taskKey = s.taskId ?? '';
      taskSeconds[taskKey] = (taskSeconds[taskKey] ?? 0) + s.durationSeconds;
      days.add('${started.year}-${started.month}-${started.day}');
      total += s.durationSeconds;
    }

    String catName(String key) =>
        key == noCategory ? 'Senza categoria' : (categories[key]?.name ?? '?');
    Color catColor(String key) => key == noCategory
        ? neutralColor
        : parseHexColor(categories[key]?.color);

    final series = [
      for (final key in catSeconds.keys)
        CategorySeries(
          catName(key),
          catColor(key),
          catSeconds[key]!,
          catBuckets[key]!,
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final byTime = taskSeconds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topTasks = [
      for (final e in byTime.take(10))
        () {
          final task = tasks[e.key];
          final catKey = task?.categoryId ?? noCategory;
          return TaskTotal(
            task == null
                ? 'Senza task'
                : (task.title.isEmpty ? '(senza titolo)' : task.title),
            catName(catKey),
            catColor(catKey),
            e.value,
          );
        }(),
    ];
    if (byTime.length > 10) {
      final rest = byTime.skip(10);
      topTasks.add(
        TaskTotal(
          'Altri ${rest.length} task',
          '',
          neutralColor,
          rest.fold(0, (sum, e) => sum + e.value),
        ),
      );
    }

    return HistoryReport(
      start: start,
      end: end,
      group: group,
      bucketLabels: labels,
      categories: series,
      tasks: topTasks,
      sessions: matching,
      totalSeconds: total,
      activeDays: days.length,
    );
  }

  static (String, String) _bucket(DateTime d, HistoryGroup group) {
    switch (group) {
      case HistoryGroup.week:
        final monday = DateTime(d.year, d.month, d.day - (d.weekday - 1));
        return (
          'w${monday.year}-${monday.month}-${monday.day}',
          '${monday.day} ${_months[monday.month - 1]}',
        );
      case HistoryGroup.month:
        return ('m${d.year}-${d.month}', '${_months[d.month - 1]} ${d.year}');
      case HistoryGroup.day:
      case HistoryGroup.auto:
        return (
          'd${d.year}-${d.month}-${d.day}',
          '${d.day} ${_months[d.month - 1]}',
        );
    }
  }
}

/// "#rrggbb" → Color; anything else → [neutralColor].
Color parseHexColor(String? hex) {
  final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex ?? '');
  return m == null
      ? neutralColor
      : Color(0xFF000000 | int.parse(m[1]!, radix: 16));
}

/// 3725 → "1h 02m", 300 → "5m".
String formatHours(int seconds) {
  final minutes = (seconds / 60).round();
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
}

/// "1 ott 2026".
String formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
