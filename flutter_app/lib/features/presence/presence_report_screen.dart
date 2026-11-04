import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/providers.dart';
import '../history/history_report.dart';
import '../history/report_widgets.dart';
import 'presence_controller.dart';
import 'presence_report.dart';

class PresenceStays {
  final List<StayRow> stays;

  /// The server couldn't be reached: only this device's stays.
  final bool offline;

  const PresenceStays(this.stays, {this.offline = false});
}

/// Stays for the report: every device's, from the server, plus this
/// device's not uploaded yet. Offline, this device's only.
final presenceStaysProvider = FutureProvider.autoDispose<PresenceStays>((
  ref,
) async {
  final db = ref.watch(appDatabaseProvider);
  final config = ref.watch(presenceProvider.select((s) => s.config));
  final slots = {for (final p in config.places) p.id: p.slot};
  final local = [
    for (final p in await db.presencesDao.getAll())
      StayRow(
        id: p.id,
        place: p.placeId,
        placeName: p.placeName,
        slot: slots[p.placeId] ?? 0,
        method: p.method,
        enteredAt: p.enteredAt,
        exitedAt: p.exitedAt,
        lastSeenAt: p.lastSeenAt,
      ),
  ];
  try {
    final data = await ref
        .read(apiClientProvider)
        .get('/presence/stays', params: {'from': '0'});
    final remote = [
      for (final s in data['stays'] as List)
        StayRow.fromJson(s as Map<String, dynamic>),
    ];
    // A local stay not on the server yet, or newer than its copy there.
    final byId = {for (final s in remote) s.id: s};
    for (final s in local) {
      final r = byId[s.id];
      if (r == null ||
          s.lastSeenAt > r.lastSeenAt ||
          (s.exitedAt != null && r.exitedAt == null)) {
        byId[s.id] = StayRow(
          id: s.id,
          place: r?.place ?? s.place,
          placeName: s.placeName,
          slot: r?.slot ?? s.slot,
          device: r?.device ?? '',
          method: s.method,
          enteredAt: s.enteredAt,
          exitedAt: s.exitedAt,
          lastSeenAt: s.lastSeenAt,
        );
      }
    }
    return PresenceStays(byId.values.toList());
  } catch (e) {
    debugPrint('[Presence] stays download failed: $e');
    return PresenceStays(local, offline: true);
  }
});

/// Kept while the app runs, so leaving the screen doesn't reset them.
final presenceFiltersProvider = StateProvider<HistoryFilters>(
  (ref) => const HistoryFilters(period: HistoryPeriod.week),
);
final _placeFilterProvider = StateProvider<String?>((ref) => null);
final _showChartsProvider = StateProvider<bool>((ref) => true);

/// The timeline has one row per day: only for short ranges.
const _timelineMaxDays = 31;

class PresenceReportScreen extends ConsumerWidget {
  const PresenceReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(presenceStaysProvider);
    final filters = ref.watch(presenceFiltersProvider);
    final place = ref.watch(_placeFilterProvider);
    final showCharts = ref.watch(_showChartsProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color color(int slot) => placeColor(slot, dark: dark);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report presenze'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(presenceStaysProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (data) {
          final report = PresenceReport.build(
            stays: data.stays,
            filters: filters,
            place: place,
            now: DateTime.now(),
          );
          // Places to filter by: those with stays, by name.
          final placeNames = <String, String>{
            for (final s in data.stays) s.place: s.placeName,
          };
          final theme = Theme.of(context);
          final avg = report.days.isEmpty
              ? '—'
              : formatHours(report.totalSeconds ~/ report.days.length);

          return RefreshIndicator(
            onRefresh: () => ref.refresh(presenceStaysProvider.future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (data.offline)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Server non raggiungibile: solo le presenze di questo dispositivo.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    PeriodChip(
                      filters: filters,
                      onChanged: (f) =>
                          ref.read(presenceFiltersProvider.notifier).state = f,
                    ),
                    FilterChipButton(
                      icon: Icons.place_outlined,
                      label: place == null
                          ? 'Tutti i luoghi'
                          : placeNames[place] ?? '?',
                      active: place != null,
                      onTap: () async {
                        final picked =
                            await pickOption<String?>(context, 'Luogo', [
                              const PickOption(null, 'Tutti i luoghi'),
                              for (final e
                                  in placeNames.entries.toList()..sort(
                                    (a, b) => a.value.toLowerCase().compareTo(
                                      b.value.toLowerCase(),
                                    ),
                                  ))
                                PickOption(e.key, e.value),
                            ], place);
                        if (picked != null) {
                          ref.read(_placeFilterProvider.notifier).state =
                              picked.value;
                        }
                      },
                    ),
                    GroupChip(
                      filters: filters,
                      onChanged: (f) =>
                          ref.read(presenceFiltersProvider.notifier).state = f,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _rangeText(report),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ReportStat('Nei luoghi', formatHours(report.totalSeconds)),
                    ReportStat('Giorni', '${report.days.length}'),
                    ReportStat('Media/giorno', avg),
                    ReportStat('Permanenze', '${report.stays.length}'),
                  ],
                ),
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
                      label: Text('Elenco'),
                    ),
                  ],
                  selected: {showCharts},
                  onSelectionChanged: (v) =>
                      ref.read(_showChartsProvider.notifier).state = v.first,
                ),
                const SizedBox(height: 12),
                if (report.stays.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'Nessuna presenza con questi filtri.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else if (showCharts) ...[
                  ReportCard(
                    title: 'Ore per ${_groupWord(report.group)}, per luogo',
                    child: StackedHoursChart(
                      labels: report.bucketLabels,
                      series: [
                        for (final p in report.places)
                          CategorySeries(
                            p.name,
                            color(p.slot),
                            p.seconds,
                            p.buckets,
                          ),
                      ],
                    ),
                  ),
                  ReportCard(
                    title: 'Per luogo',
                    child: BarList(
                      items: [
                        for (final p in [
                          ...report.places,
                        ]..sort((a, b) => b.seconds.compareTo(a.seconds)))
                          BarItem(p.name, null, color(p.slot), p.seconds),
                      ],
                    ),
                  ),
                  ReportCard(
                    title: 'Orari tipici',
                    child: _TypicalHours(report: report, color: color),
                  ),
                  if (report.rangeDays.length <= _timelineMaxDays)
                    ReportCard(
                      title: 'Orari di presenza, giorno per giorno',
                      child: _Timeline(report: report, color: color),
                    ),
                  Text(
                    'Entrata e uscita medie: della prima entrata e dell\'ultima '
                    'uscita di ogni giorno. Le permanenze di più dispositivi '
                    'nello stesso luogo sono unite.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ] else
                  ..._list(context, report, color),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _rangeText(PresenceReport r) {
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

  /// Days (newest first), each with its places, then every stay.
  static List<Widget> _list(
    BuildContext context,
    PresenceReport report,
    Color Function(int) color,
  ) {
    final theme = Theme.of(context);
    final tabular = theme.textTheme.titleSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final d in report.days) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  DateFormat('EEEE d MMMM', 'it').format(d.day),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(formatHours(d.seconds), style: tabular),
            ],
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final e in d.entries)
                ListTile(
                  dense: true,
                  leading: _Dot(color(e.slot)),
                  title: Text(e.name),
                  subtitle: Text(
                    '${_time(e.first)} – ${e.open ? 'presente' : _time(e.last)}',
                  ),
                  trailing: Text(
                    formatHours(e.seconds),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 6),
        child: Text('Permanenze registrate', style: theme.textTheme.titleSmall),
      ),
      Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            for (final s in report.stays)
              ListTile(
                dense: true,
                leading: _Dot(color(s.slot)),
                title: Text(s.placeName),
                subtitle: Text(
                  [
                    '${DateFormat('d/M HH:mm').format(DateTime.fromMillisecondsSinceEpoch(s.enteredAt))}'
                        ' – ${s.isOpen(now) ? 'in corso' : _time(s.endAt(now))}'
                        '${s.exitedAt == null && !s.isOpen(now) ? ' *' : ''}',
                    ?_device(s.device),
                    ?_methods[s.method],
                  ].join(' · '),
                ),
                trailing: Text(
                  formatHours((s.endAt(now) - s.enteredAt) ~/ 1000),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '* il dispositivo ha smesso di rispondere: uscita all\'ultimo '
          'rilevamento.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    ];
  }

  static const _methods = {
    'gps': 'GPS',
    'wifi': 'Wi-Fi',
    'gps+wifi': 'GPS + Wi-Fi',
  };

  static String? _device(String d) => switch (d) {
    '' => null,
    'android' => 'Android',
    'iOS' => 'iPhone',
    'linux' => 'Linux',
    'windows' => 'Windows',
    'macOS' => 'Mac',
    'web' => 'Browser',
    _ => d,
  };
}

String _time(int ms) =>
    DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));

/// "08:55" from minutes after midnight.
String _clock(int? minutes) => minutes == null
    ? '—'
    : '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
          '${(minutes % 60).toString().padLeft(2, '0')}';

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot(this.color);

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Per place: days present, average first entry and last exit, average
/// time per day present.
class _TypicalHours extends StatelessWidget {
  final PresenceReport report;
  final Color Function(int) color;

  const _TypicalHours({required this.report, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    final cell = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget pad(Widget w) =>
        Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: w);
    return Table(
      columnWidths: const {0: FlexColumnWidth(2.2)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            for (final h in [
              'Luogo',
              'Giorni',
              'Entrata',
              'Uscita',
              'Al giorno',
            ])
              pad(Text(h, style: head)),
          ],
        ),
        for (final p in report.places)
          TableRow(
            children: [
              pad(
                Row(
                  children: [
                    _Dot(color(p.slot)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.name,
                        style: cell,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              pad(Text('${p.days}', style: cell)),
              pad(Text(_clock(p.avgIn), style: cell)),
              pad(Text(_clock(p.avgOut), style: cell)),
              pad(
                Text(
                  p.days == 0 ? '—' : formatHours(p.seconds ~/ p.days),
                  style: cell?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// One row per day, 00–24: when the device was in each place.
class _Timeline extends StatelessWidget {
  final PresenceReport report;
  final Color Function(int) color;

  const _Timeline({required this.report, required this.color});

  static const _rowHeight = 18.0;
  static const _labelWidth = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurfaceVariant;
    final grid = theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
    final surface =
        theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;
    final byDay = <DateTime, List<DaySpan>>{};
    for (final s in report.spans) {
      byDay.putIfAbsent(s.day, () => []).add(s);
    }
    final places = {for (final p in report.places) p.key: p};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (report.places.length > 1) ...[
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final p in report.places)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(color(p.slot)),
                    const SizedBox(width: 4),
                    Text(p.name, style: theme.textTheme.bodySmall),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        for (final day in report.rangeDays)
          SizedBox(
            height: _rowHeight + 4,
            child: Row(
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Text(
                    DateFormat('E d', 'it').format(day),
                    style: TextStyle(fontSize: 10, color: ink),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Stack(
                      children: [
                        for (var h = 0; h <= 24; h += 6)
                          Positioned(
                            left: c.maxWidth * h / 24,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1, color: grid),
                          ),
                        for (final s in byDay[day] ?? const <DaySpan>[])
                          Positioned(
                            left: c.maxWidth * s.from / 24,
                            width: (c.maxWidth * (s.to - s.from) / 24).clamp(
                              2.0,
                              c.maxWidth,
                            ),
                            top: 2,
                            height: _rowHeight,
                            child: Tooltip(
                              message:
                                  '${places[s.place]?.name ?? ''}: '
                                  '${_hours(s.from)} – ${_hours(s.to)}',
                              child: Container(
                                decoration: BoxDecoration(
                                  color: color(s.slot),
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(color: surface),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: _labelWidth, top: 4),
          child: LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: 14,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var h = 0; h <= 24; h += 6)
                    Positioned(
                      left: (c.maxWidth * h / 24 - (h == 24 ? 28 : 0)),
                      child: Text(
                        '${h.toString().padLeft(2, '0')}:00',
                        style: TextStyle(fontSize: 10, color: ink),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _hours(double h) => _clock((h * 60).round());
}
