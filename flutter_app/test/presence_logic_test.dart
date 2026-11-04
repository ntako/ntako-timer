import 'package:flutter_test/flutter_test.dart';
import 'package:workadoro/features/presence/presence_logic.dart';

const office = Place(
  id: 'office',
  name: 'Ufficio',
  latitude: 45.4642,
  longitude: 9.1900,
  radiusM: 100,
  wifi: ['Office', 'A4-2B-B0-12-34-56'],
);
const gpsOnly = Place(id: 'g', name: 'G', latitude: 45.0, longitude: 9.0);
const wifiOnly = Place(id: 'w', name: 'W', wifi: ['Home']);

const now = 1_800_000_000_000;

/// A fix [metres] north of the office.
Fix north(double metres, {double accuracy = 20, int age = 0}) =>
    Fix(45.4642 + metres / 111_195, 9.19, accuracy, now - age);

Observation obs({Fix? fix, WifiInfo? wifi}) =>
    Observation(atMs: now, fix: fix, wifi: wifi);

void main() {
  group('distance', () {
    test('about 111 km per degree of latitude', () {
      expect(distanceM(45, 9, 46, 9), closeTo(111_195, 50));
    });
  });

  group('gps evidence', () {
    test('inside the radius with a good fix', () {
      expect(gpsEvidence(office, north(60), now), Evidence.match);
    });

    test('outside even counting the error', () {
      expect(gpsEvidence(office, north(300, accuracy: 50), now), Evidence.miss);
    });

    test('a vague fix near the edge says nothing', () {
      expect(
        gpsEvidence(office, north(150, accuracy: 80), now),
        Evidence.unknown,
      );
      // Inside, but accurate only to 400 m: can't tell.
      expect(
        gpsEvidence(office, north(50, accuracy: 400), now),
        Evidence.unknown,
      );
    });

    test('an old fix says nothing', () {
      expect(
        gpsEvidence(office, north(10, age: maxFixAgeMs + 1), now),
        Evidence.unknown,
      );
    });

    test('a place without position has no gps evidence', () {
      expect(gpsEvidence(wifiOnly, north(0), now), isNull);
    });
  });

  group('wifi evidence', () {
    test('by network name', () {
      expect(
        wifiEvidence(office, const WifiInfo(ssid: 'Office')),
        Evidence.match,
      );
    });

    test('by access point, whatever the notation', () {
      expect(
        wifiEvidence(
          office,
          const WifiInfo(ssid: 'Guest', bssid: 'a4:2b:b0:12:34:56'),
        ),
        Evidence.match,
      );
    });

    test('another network or none is a miss', () {
      expect(wifiEvidence(office, const WifiInfo(ssid: 'Bar')), Evidence.miss);
      expect(wifiEvidence(office, WifiInfo.none), Evidence.miss);
    });

    test('unreadable wifi says nothing', () {
      expect(wifiEvidence(office, null), Evidence.unknown);
    });
  });

  group('modes', () {
    const onWifi = WifiInfo(ssid: 'Office');

    test('gps only ignores wifi', () {
      expect(
        evaluate(
          office,
          TrackingMode.gps,
          obs(fix: north(500), wifi: onWifi),
        ).evidence,
        Evidence.miss,
      );
    });

    test('wifi only ignores gps', () {
      final r = evaluate(
        office,
        TrackingMode.wifi,
        obs(fix: north(500), wifi: onWifi),
      );
      expect(r.evidence, Evidence.match);
      expect(r.method, 'wifi');
    });

    test('single-source mode never detects a place lacking that source', () {
      expect(
        evaluate(wifiOnly, TrackingMode.gps, obs(fix: north(0))).evidence,
        Evidence.miss,
      );
    });

    test('and: both needed', () {
      final both = evaluate(
        office,
        TrackingMode.gpsAndWifi,
        obs(fix: north(20), wifi: onWifi),
      );
      expect(both.evidence, Evidence.match);
      expect(both.method, 'gps+wifi');
      expect(
        evaluate(
          office,
          TrackingMode.gpsAndWifi,
          obs(fix: north(20), wifi: WifiInfo.none),
        ).evidence,
        Evidence.miss,
      );
      expect(
        evaluate(office, TrackingMode.gpsAndWifi, obs(wifi: onWifi)).evidence,
        Evidence.unknown,
      );
    });

    test('and: a place with only a position uses gps alone', () {
      expect(
        evaluate(
          gpsOnly,
          TrackingMode.gpsAndWifi,
          obs(fix: const Fix(45, 9, 10, now), wifi: WifiInfo.none),
        ).evidence,
        Evidence.match,
      );
    });

    test('or: either is enough, miss only when both miss', () {
      expect(
        evaluate(office, TrackingMode.gpsOrWifi, obs(wifi: onWifi)).method,
        'wifi',
      );
      expect(
        evaluate(
          office,
          TrackingMode.gpsOrWifi,
          obs(fix: north(500), wifi: WifiInfo.none),
        ).evidence,
        Evidence.miss,
      );
      expect(
        evaluate(
          office,
          TrackingMode.gpsOrWifi,
          obs(wifi: WifiInfo.none),
        ).evidence,
        Evidence.unknown,
      );
    });
  });

  group('stays', () {
    const match = PlaceMatch(Evidence.match, 'wifi');

    test('a match outside starts a stay', () {
      final c = step(open: const [], results: {'office': match}, nowMs: now);
      expect(c.single, isA<StayEnter>());
      expect((c.single as StayEnter).method, 'wifi');
    });

    test('a match inside extends it', () {
      final c = step(
        open: const [OpenStay('s', 'office', now - 60_000)],
        results: {'office': match},
        nowMs: now,
      );
      expect(c.single, isA<StaySeen>());
    });

    test('misses within the grace period keep the stay', () {
      final c = step(
        open: const [OpenStay('s', 'office', now - exitGraceMs + 1)],
        results: {'office': PlaceMatch.miss},
        nowMs: now,
      );
      expect(c, isEmpty);
    });

    test('misses after the grace period end it at the last detection', () {
      final c = step(
        open: const [OpenStay('s', 'office', now - exitGraceMs)],
        results: {'office': PlaceMatch.miss},
        nowMs: now,
      );
      expect((c.single as StayExit).at, now - exitGraceMs);
    });

    test('no evidence keeps the stay, until it is stale', () {
      expect(
        step(
          open: const [OpenStay('s', 'office', now - 10 * 60_000)],
          results: {'office': PlaceMatch.unknown},
          nowMs: now,
        ),
        isEmpty,
      );
      expect(
        step(
          open: const [OpenStay('s', 'office', now - staleMs - 1)],
          results: {'office': PlaceMatch.unknown},
          nowMs: now,
        ).single,
        isA<StayExit>(),
      );
    });

    test('after a long gap a match starts a new stay', () {
      // App closed in the office in the evening, reopened there next morning.
      final c = step(
        open: const [OpenStay('s', 'office', now - 14 * 3600_000)],
        results: {'office': match},
        nowMs: now,
      );
      expect(c, hasLength(2));
      expect((c[0] as StayExit).at, now - 14 * 3600_000);
      expect(c[1], isA<StayEnter>());
    });

    test('a removed place ends its stay', () {
      final c = step(
        open: const [OpenStay('s', 'gone', now - 60_000)],
        results: const {},
        nowMs: now,
      );
      expect(c.single, isA<StayExit>());
    });
  });

  test('config round trip', () {
    final config = PresenceConfig.fromJson({
      'policy': 'user',
      'mode': 'gps_and_wifi',
      'can_edit': true,
      'places': [office.toJson()],
    });
    final again = PresenceConfig.fromJson(config.toJson());
    expect(again.policy, PresencePolicy.user);
    expect(again.mode, TrackingMode.gpsAndWifi);
    expect(again.places.single.wifi, office.wifi);
    expect(again.places.single.radiusM, 100);
    expect(PresencePolicy.parse('nonsense'), PresencePolicy.off);
  });

  group('check interval', () {
    test('exit needs at least two missed checks', () {
      expect(exitGraceFor(1), exitGraceMs);
      expect(exitGraceFor(5), 10 * 60 * 1000);
      expect(exitGraceFor(10), 20 * 60 * 1000);
      // Every interval keeps a check plus an upload within the stale limit.
      expect(checkIntervals.every((m) => exitGraceFor(m) < staleMs), isTrue);
    });

    test('with checks every 5 minutes one miss keeps the stay', () {
      final open = [const OpenStay('s', 'office', now - 5 * 60 * 1000)];
      final grace = exitGraceFor(5);
      expect(
        step(
          open: open,
          results: {'office': PlaceMatch.miss},
          nowMs: now,
          graceMs: grace,
        ),
        isEmpty,
      );
      expect(
        step(
          open: [const OpenStay('s', 'office', now - 10 * 60 * 1000)],
          results: {'office': PlaceMatch.miss},
          nowMs: now,
          graceMs: grace,
        ).single,
        isA<StayExit>(),
      );
    });
  });
}
