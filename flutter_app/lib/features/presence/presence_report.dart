import 'dart:math';
import 'package:flutter/painting.dart';
import '../history/history_report.dart';
import 'presence_logic.dart';

/// Presence report: same periods and grouping as the task history, same
/// rules as the admin panel (backend/admin/presence.php buildPresenceReport).
///
/// Stays of several devices in the same place are merged first, so time is
/// not counted twice; then split at midnight, each day getting the time
/// spent in it.

/// Place colors by slot (from the server, in creation order): the
/// categorical palette, light and dark steps. Slot 0 = neutral.
const _light = [
  Color(0xFF2A78D6),
  Color(0xFFEB6834),
  Color(0xFF1BAF7A),
  Color(0xFFEDA100),
  Color(0xFFE87BA4),
  Color(0xFF008300),
  Color(0xFF6250D6),
  Color(0xFFE34948),
];
const _dark = [
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

Color placeColor(int slot, {bool dark = false}) =>
    slot < 1 || slot > 8 ? neutralColor : (dark ? _dark : _light)[slot - 1];

/// One stay as recorded by a device.
class StayRow {
  final String id;

  /// The place's client_id, or `n:<name>` when the place is gone.
  final String place;
  final String placeName;
  final int slot;
  final String device;
  final String method;
  final int enteredAt;
  final int? exitedAt;
  final int lastSeenAt;

  const StayRow({
    required this.id,
    required this.place,
    required this.placeName,
    this.slot = 0,
    this.device = '',
    this.method = '',
    required this.enteredAt,
    this.exitedAt,
    required this.lastSeenAt,
  });

  factory StayRow.fromJson(Map<String, dynamic> m) => StayRow(
    id: m['client_id'] as String,
    place: m['place'] as String,
    placeName: m['place_name'] as String,
    slot: (m['slot'] as num?)?.toInt() ?? 0,
    device: (m['device'] as String?) ?? '',
    method: (m['method'] as String?) ?? '',
    enteredAt: (m['entered_at'] as num).toInt(),
    exitedAt: (m['exited_at'] as num?)?.toInt(),
    lastSeenAt: (m['last_seen_at'] as num).toInt(),
  );

  /// Still inside: not exited, and the device reported recently.
  bool isOpen(int nowMs) => exitedAt == null && nowMs - lastSeenAt < staleMs;

  /// Exit time, or now while open, or the last detection when the device
  /// went silent.
  int endAt(int nowMs) => exitedAt ?? (isOpen(nowMs) ? nowMs : lastSeenAt);
}

class PlaceTotal {
  final String key;
  final String name;
  final int slot;
  final int seconds;
  final List<int> buckets;
  final int days;

  /// Averages of each day's first entry and last exit, minutes after
  /// midnight; null without data.
  final int? avgIn;
  final int? avgOut;

  const PlaceTotal({
    required this.key,
    required this.name,
    required this.slot,
    required this.seconds,
    required this.buckets,
    required this.days,
    this.avgIn,
    this.avgOut,
  });
}

/// Time in one place on one day.
class DayEntry {
  final String place;
  final String name;
  final int slot;
  final int first;
  final int last;
  final int seconds;
  final bool open;

  const DayEntry(
    this.place,
    this.name,
    this.slot,
    this.first,
    this.last,
    this.seconds,
    this.open,
  );
}

class PresenceDay {
  final DateTime day;
  final List<DayEntry> entries;

  const PresenceDay(this.day, this.entries);

  int get seconds => entries.fold(0, (s, e) => s + e.seconds);
}

/// A presence interval on one day, in hours after midnight (timeline).
class DaySpan {
  final DateTime day;
  final String place;
  final int slot;
  final double from;
  final double to;

  const DaySpan(this.day, this.place, this.slot, this.from, this.to);
}

class PresenceReport {
  final DateTime start;
  final DateTime end;
  final HistoryGroup group;
  final List<String> bucketLabels;

  /// Sorted by name: a place keeps its position whatever the filter.
  final List<PlaceTotal> places;

  /// Newest day first.
  final List<PresenceDay> days;

  /// Every day of the range, oldest first, and what happened in it.
  final List<DateTime> rangeDays;
  final List<DaySpan> spans;

  /// Stays matching the filters, newest first.
  final List<StayRow> stays;
  final int totalSeconds;

  const PresenceReport({
    required this.start,
    required this.end,
    required this.group,
    required this.bucketLabels,
    required this.places,
    required this.days,
    required this.rangeDays,
    required this.spans,
    required this.stays,
    required this.totalSeconds,
  });

  static PresenceReport build({
    required List<StayRow> stays,
    required HistoryFilters filters,
    String? place,
    required DateTime now,
  }) {
    final nowMs = now.millisecondsSinceEpoch;
    final first = stays.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            stays.map((s) => s.enteredAt).reduce(min),
          );
    final (start, end) = filters.range(now, firstSession: first);
    final group = filters.effectiveGroup(start, end);
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;

    final bucketIndex = <String, int>{};
    final labels = <String>[];
    final rangeDays = <DateTime>[];
    for (
      var d = start;
      d.isBefore(end);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      rangeDays.add(d);
      final (key, label) = bucketOf(d, group);
      if (!bucketIndex.containsKey(key)) {
        bucketIndex[key] = labels.length;
        labels.add(label);
      }
    }

    final matching =
        stays
            .where(
              (s) =>
                  (place == null || s.place == place) &&
                  s.enteredAt < endMs &&
                  s.endAt(nowMs) >= startMs,
            )
            .toList()
          ..sort((a, b) => b.enteredAt.compareTo(a.enteredAt));

    // Clipped intervals per place.
    final names = <String, String>{};
    final slots = <String, int>{};
    final intervals = <String, List<(int, int, bool)>>{};
    for (final s in matching) {
      final e = s.endAt(nowMs);
      final from = max(s.enteredAt, startMs);
      final to = min(e, endMs);
      if (to <= from) continue;
      names[s.place] = s.placeName;
      slots[s.place] = s.slot;
      intervals.putIfAbsent(s.place, () => []).add((
        from,
        to,
        s.isOpen(nowMs) && to == e,
      ));
    }

    final daily = <DateTime, Map<String, DayEntry>>{};
    final spans = <DaySpan>[];
    final places = <PlaceTotal>[];
    for (final MapEntry(key: key, value: list) in intervals.entries) {
      var seconds = 0;
      final buckets = List.filled(labels.length, 0);
      for (final (from, to, open) in merge(list)) {
        var cur = from;
        while (cur < to) {
          final t = DateTime.fromMillisecondsSinceEpoch(cur);
          final day = DateTime(t.year, t.month, t.day);
          final next = DateTime(
            t.year,
            t.month,
            t.day + 1,
          ).millisecondsSinceEpoch;
          final slice = min(to, next);
          final secs = (slice - cur) ~/ 1000;
          final dayMs = day.millisecondsSinceEpoch;

          final entries = daily.putIfAbsent(day, () => {});
          final prev = entries[key];
          entries[key] = DayEntry(
            key,
            names[key]!,
            slots[key]!,
            prev?.first ?? cur,
            max(prev?.last ?? slice, slice),
            (prev?.seconds ?? 0) + secs,
            (prev?.open ?? false) || (open && slice == to),
          );
          seconds += secs;
          final i = bucketIndex[bucketOf(day, group).$1];
          if (i != null) buckets[i] += secs;
          spans.add(
            DaySpan(
              day,
              key,
              slots[key]!,
              (cur - dayMs) / 3_600_000,
              (slice - dayMs) / 3_600_000,
            ),
          );
          cur = slice;
        }
      }

      final ins = <int>[];
      final outs = <int>[];
      for (final MapEntry(key: day, value: entries) in daily.entries) {
        final e = entries[key];
        if (e == null) continue;
        final midnight = day.millisecondsSinceEpoch;
        ins.add((e.first - midnight) ~/ 60000);
        if (!e.open) outs.add((e.last - midnight) ~/ 60000);
      }
      int? avg(List<int> v) =>
          v.isEmpty ? null : (v.reduce((a, b) => a + b) / v.length).round();
      places.add(
        PlaceTotal(
          key: key,
          name: names[key]!,
          slot: slots[key]!,
          seconds: seconds,
          buckets: buckets,
          days: ins.length,
          avgIn: avg(ins),
          avgOut: avg(outs),
        ),
      );
    }
    places.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final days = [
      for (final e in daily.entries)
        PresenceDay(
          e.key,
          e.value.values.toList()..sort((a, b) => a.first.compareTo(b.first)),
        ),
    ]..sort((a, b) => b.day.compareTo(a.day));

    return PresenceReport(
      start: start,
      end: end,
      group: group,
      bucketLabels: labels,
      places: places,
      days: days,
      rangeDays: rangeDays,
      spans: spans,
      stays: matching,
      totalSeconds: places.fold(0, (s, p) => s + p.seconds),
    );
  }

  /// Sorted, non-overlapping; the open flag follows the latest end.
  static List<(int, int, bool)> merge(List<(int, int, bool)> list) {
    final sorted = [...list]..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, int, bool)>[];
    for (final i in sorted) {
      if (out.isNotEmpty && i.$1 <= out.last.$2) {
        final last = out.removeLast();
        out.add(
          i.$2 > last.$2
              ? (last.$1, i.$2, i.$3)
              : (last.$1, last.$2, last.$3 || (i.$2 == last.$2 && i.$3)),
        );
      } else {
        out.add(i);
      }
    }
    return out;
  }
}
