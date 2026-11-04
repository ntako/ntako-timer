import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workadoro/core/database/app_database.dart';
import 'package:workadoro/core/network/api_client.dart';
import 'package:workadoro/features/presence/presence_engine.dart';
import 'package:workadoro/features/presence/presence_logic.dart';

/// Acknowledges every pushed stay; serves the config.
class FakeApi implements ApiClient {
  final pushes = <List>[];
  Map<String, dynamic> config = {};

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final rows = data['presences'] as List;
    pushes.add(rows);
    return {
      'synced_presences': [
        for (final (i, r) in rows.indexed)
          {'client_id': (r as Map)['client_id'], 'server_id': i + 1},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? params,
  }) async => config;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const office = Place(id: 'office', name: 'Arundo', wifi: ['Office']);
const onOfficeWifi = WifiInfo(ssid: 'Office');

void main() {
  late AppDatabase db;
  late FakeApi api;
  late int now;
  WifiInfo? wifi;
  late PresenceEngine engine;

  Future<void> configure({
    bool enabled = true,
    int interval = 1,
    TrackingMode mode = TrackingMode.wifi,
  }) async {
    final config = PresenceConfig(
      policy: PresencePolicy.user,
      mode: mode,
      canEdit: true,
      places: const [office],
    );
    api.config = config.toJson();
    await db.settingsDao.setValue(
      PresenceKeys.config,
      jsonEncode(config.toJson()),
    );
    await db.settingsDao.setValue(PresenceKeys.enabled, enabled ? '1' : '0');
    await db.settingsDao.setValue(PresenceKeys.mode, mode.wire);
    await db.settingsDao.setValue(PresenceKeys.interval, '$interval');
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeApi();
    now = DateTime(2026, 11, 4, 10).millisecondsSinceEpoch;
    wifi = WifiInfo.none;
    engine = PresenceEngine(
      db: db,
      api: api,
      isLoggedIn: () async => true,
      readWifi: () async => wifi,
      readFix: () async => null,
      locationProblem: ({required bool request}) async => null,
      clock: () => now,
    );
    await configure();
  });
  tearDown(() => db.close());

  Future<CheckOutcome> minute([int n = 1]) async {
    now += n * 60 * 1000;
    return engine.check();
  }

  Future<List<String>> log() async => [
    for (final e in await PresenceEngine.readLog(db)) e.message,
  ];

  test(
    'a day at the office: entry, stay, exit at the last detection',
    () async {
      await engine.check(force: true);
      expect(await db.presencesDao.getOpen(), isEmpty);

      wifi = onOfficeWifi;
      final arrived = now + 60 * 1000;
      final entered = await minute();
      expect(entered.last!.inside, ['Arundo']);
      expect((await db.presencesDao.getOpen()).single.enteredAt, arrived);
      expect(api.pushes, isNotEmpty, reason: 'an entry is sent at once');

      for (var i = 0; i < 30; i++) {
        await minute();
      }
      final lastSeen = now;
      wifi = WifiInfo.none;
      await minute(); // one miss: still inside
      await minute();
      expect(await db.presencesDao.getOpen(), hasLength(1));
      await minute(); // 3 minutes without the network: out
      expect(await db.presencesDao.getOpen(), isEmpty);
      final stay = (await db.presencesDao.getAll()).single;
      expect(stay.exitedAt, lastSeen);
      expect(await log(), contains(startsWith('Uscita: Arundo')));
      expect(await log(), contains(startsWith('Entrata: Arundo')));
    },
  );

  test('checks closer than the interval are skipped', () async {
    await configure(interval: 5);
    expect((await engine.check(force: true)).ran, isTrue);
    expect((await minute()).ran, isFalse);
    expect((await minute(4)).ran, isTrue);
  });

  test('a long pause is logged and does not stretch the stay', () async {
    wifi = onOfficeWifi;
    await engine.check(force: true);
    final lastSeen = now;

    // App closed at the office; reopened there two hours later.
    now += 2 * 3600 * 1000;
    final fresh = PresenceEngine(
      db: db,
      api: api,
      isLoggedIn: () async => true,
      readWifi: () async => wifi,
      readFix: () async => null,
      locationProblem: ({required bool request}) async => null,
      clock: () => now,
    );
    await fresh.check();

    final stays = await db.presencesDao.getAll()
      ..sort((a, b) => a.enteredAt.compareTo(b.enteredAt));
    expect(stays, hasLength(2));
    expect(stays.first.exitedAt, lastSeen);
    expect(stays.last.exitedAt, isNull);
    expect(await log(), contains(startsWith('Nessun controllo per 2h 00m')));
  });

  test('turned off: open stays close and detection reports inactive', () async {
    wifi = onOfficeWifi;
    await engine.check(force: true);
    await configure(enabled: false);
    final outcome = await minute();
    expect(outcome.active, isFalse);
    expect(await db.presencesDao.getOpen(), isEmpty);
  });

  test('a missing permission is logged once, not every minute', () async {
    await configure(mode: TrackingMode.gps);
    engine = PresenceEngine(
      db: db,
      api: api,
      isLoggedIn: () async => true,
      readWifi: () async => wifi,
      readFix: () async => null,
      locationProblem: ({required bool request}) async => 'Permesso negato',
      clock: () => now,
    );
    await engine.check(force: true);
    await minute();
    await minute();
    expect((await log()).where((m) => m == 'Permesso negato'), hasLength(1));
    expect((await PresenceEngine.readLast(db))!.problem, 'Permesso negato');
  });
}
