import 'package:flutter_test/flutter_test.dart';
import 'package:workadoro/features/history/history_report.dart';
import 'package:workadoro/features/presence/presence_report.dart';

int at(int day, int h, [int m = 0]) =>
    DateTime(2026, 10, day, h, m).millisecondsSinceEpoch;

StayRow stay(
  String place,
  int from,
  int? to, {
  String device = 'android',
  int? lastSeen,
}) => StayRow(
  id: '$place-$from-$device',
  place: place,
  placeName: place == 'o' ? 'Ufficio' : 'Casa',
  slot: place == 'o' ? 1 : 2,
  device: device,
  enteredAt: from,
  exitedAt: to,
  lastSeenAt: lastSeen ?? to ?? from,
);

final now = DateTime(2026, 10, 30, 12);
PresenceReport build(List<StayRow> stays, {String? place}) =>
    PresenceReport.build(
      stays: stays,
      filters: HistoryFilters(
        period: HistoryPeriod.custom,
        customFrom: DateTime(2026, 10, 19),
        customTo: DateTime(2026, 10, 25),
      ),
      place: place,
      now: now,
    );

void main() {
  test('overlapping stays of two devices count once', () {
    final r = build([
      stay('o', at(20, 9), at(20, 17)),
      stay('o', at(20, 9, 30), at(20, 18), device: 'linux'),
    ]);
    expect(r.totalSeconds, 9 * 3600);
    expect(r.stays, hasLength(2));
    final day = r.days.single;
    expect(day.entries.single.first, at(20, 9));
    expect(day.entries.single.last, at(20, 18));
  });

  test('a stay across midnight is split between the days', () {
    final r = build([stay('h', at(20, 22), at(21, 7))]);
    expect(r.days, hasLength(2));
    expect(r.days[0].seconds, 7 * 3600); // 21st, newest first
    expect(r.days[1].seconds, 2 * 3600);
    expect(r.spans.map((s) => (s.from, s.to)), [(22.0, 24.0), (0.0, 7.0)]);
  });

  test('buckets, place filter and stable order by name', () {
    final stays = [
      stay('o', at(20, 9), at(20, 17)),
      stay('h', at(20, 18), at(20, 23)),
      stay('o', at(21, 9), at(21, 13)),
    ];
    final r = build(stays);
    expect(r.bucketLabels, hasLength(7));
    expect(r.places.map((p) => p.name), ['Casa', 'Ufficio']);
    final office = r.places[1];
    expect(office.buckets[1], 8 * 3600); // 20 ott
    expect(office.buckets[2], 4 * 3600); // 21 ott
    expect(office.days, 2);
    expect(office.avgIn, 9 * 60);
    expect(office.avgOut, 15 * 60); // (17:00 + 13:00) / 2

    final onlyHome = build(stays, place: 'h');
    expect(onlyHome.places.single.name, 'Casa');
    expect(onlyHome.totalSeconds, 5 * 3600);
  });

  test('stays outside the range are clipped or left out', () {
    final r = build([
      stay('o', at(18, 22), at(19, 2)), // 2h on the 19th
      stay('o', at(26, 9), at(26, 17)), // after the range
    ]);
    expect(r.totalSeconds, 2 * 3600);
    expect(r.stays, hasLength(1));
  });

  test(
    'a silent device ends at its last detection; a live one counts to now',
    () {
      final silent = stay('o', at(22, 9), null, lastSeen: at(22, 11));
      expect(silent.isOpen(now.millisecondsSinceEpoch), isFalse);
      expect(build([silent]).totalSeconds, 2 * 3600);

      final live = StayRow(
        id: 'x',
        place: 'o',
        placeName: 'Ufficio',
        enteredAt: at(30, 9),
        lastSeenAt: now.millisecondsSinceEpoch - 60000,
      );
      final today = PresenceReport.build(
        stays: [live],
        filters: const HistoryFilters(period: HistoryPeriod.today),
        now: now,
      );
      expect(today.totalSeconds, 3 * 3600);
      expect(today.days.single.entries.single.open, isTrue);
      expect(today.places.single.avgOut, isNull);
    },
  );

  test('colors follow the slot, neutral beyond the palette', () {
    expect(placeColor(1), isNot(placeColor(2)));
    expect(placeColor(0), neutralColor);
    expect(placeColor(9), neutralColor);
  });
}
