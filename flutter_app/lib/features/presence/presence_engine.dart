import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import 'presence_logic.dart';
import 'presence_sensors.dart';

/// Settings keys, shared by the app and the background service (both read
/// and write the same database).
abstract final class PresenceKeys {
  static const config = 'presence_config';
  static const enabled = 'presence_enabled';
  static const mode = 'presence_mode';
  static const interval = 'presence_interval_min';

  /// The last check (see [LastCheck]).
  static const last = 'presence_last';

  /// Recent detection events, for diagnosis (see [PresenceLogEntry]).
  static const log = 'presence_log';
}

/// What the user chose on this device, plus the server's config.
class PresenceSettings {
  final PresenceConfig config;
  final bool enabled;
  final TrackingMode? deviceMode;
  final int intervalMinutes;

  const PresenceSettings({
    this.config = PresenceConfig.disabled,
    this.enabled = false,
    this.deviceMode,
    this.intervalMinutes = 1,
  });

  TrackingMode get mode => config.policy == PresencePolicy.user
      ? deviceMode ?? config.mode
      : config.mode;

  /// Detection should run: allowed, turned on, and something to detect.
  bool active({required bool loggedIn}) =>
      loggedIn &&
      config.policy != PresencePolicy.off &&
      enabled &&
      config.places.isNotEmpty;

  static int validInterval(int? minutes) =>
      checkIntervals.contains(minutes) ? minutes! : checkIntervals.first;

  static Future<PresenceSettings> load(AppDatabase db) async {
    final s = db.settingsDao;
    var config = PresenceConfig.disabled;
    final cached = await s.getValue(PresenceKeys.config);
    if (cached != null) {
      try {
        config = PresenceConfig.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('[Presence] cached config unreadable: $e');
      }
    }
    return PresenceSettings(
      config: config,
      enabled: await s.getValue(PresenceKeys.enabled) == '1',
      deviceMode: TrackingMode.tryParse(await s.getValue(PresenceKeys.mode)),
      intervalMinutes: validInterval(
        int.tryParse(await s.getValue(PresenceKeys.interval) ?? ''),
      ),
    );
  }
}

/// The last check, as shown in the app.
class LastCheck {
  final int atMs;

  /// Null: Wi-Fi not read (mode without Wi-Fi) or not readable.
  final WifiInfo? wifi;
  final bool wifiRead;
  final double? gpsAccuracyM;
  final bool gpsRead;
  final List<String> inside;
  final String? problem;

  const LastCheck({
    required this.atMs,
    this.wifi,
    this.wifiRead = false,
    this.gpsAccuracyM,
    this.gpsRead = false,
    this.inside = const [],
    this.problem,
  });

  Map<String, dynamic> toJson() => {
    'at': atMs,
    if (wifiRead)
      'wifi': wifi == null ? null : {'ssid': wifi!.ssid, 'bssid': wifi!.bssid},
    if (gpsRead) 'gps': gpsAccuracyM,
    'inside': inside,
    'problem': ?problem,
  };

  factory LastCheck.fromJson(Map<String, dynamic> m) {
    final w = m['wifi'] as Map<String, dynamic>?;
    return LastCheck(
      atMs: (m['at'] as num).toInt(),
      wifiRead: m.containsKey('wifi'),
      wifi: w == null
          ? null
          : WifiInfo(ssid: w['ssid'] as String?, bssid: w['bssid'] as String?),
      gpsRead: m.containsKey('gps'),
      gpsAccuracyM: (m['gps'] as num?)?.toDouble(),
      inside: [for (final n in (m['inside'] as List? ?? const [])) n as String],
      problem: m['problem'] as String?,
    );
  }
}

class PresenceLogEntry {
  final int atMs;
  final String message;

  const PresenceLogEntry(this.atMs, this.message);
}

/// One detection round's outcome.
class CheckOutcome {
  /// Detection should keep running.
  final bool active;

  /// The round actually ran (not skipped as too early).
  final bool ran;
  final LastCheck? last;

  const CheckOutcome({required this.active, this.ran = false, this.last});
}

/// Presence detection, independent of the UI: runs in the app or in the
/// Android background service (lib/features/presence/presence_service.dart).
/// Settings and stays live in the database, so both can share them.
class PresenceEngine {
  final AppDatabase db;
  final ApiClient api;
  final Future<bool> Function() isLoggedIn;

  /// Sensors, replaceable in tests.
  final Future<WifiInfo?> Function() readWifi;
  final Future<Fix?> Function() readFix;

  /// Null when location can be used; [request] may show a system dialog
  /// (only in the app, not in the service).
  final Future<String?> Function({required bool request}) locationProblem;

  /// May ask the user for permissions (false in the background service).
  final bool interactive;

  final int Function() clock;

  PresenceEngine({
    required this.db,
    required this.api,
    required this.isLoggedIn,
    this.readWifi = PresenceSensors.currentWifi,
    this.readFix = PresenceSensors.currentFix,
    this.locationProblem = PresenceSensors.locationProblem,
    this.interactive = false,
    int Function()? clock,
  }) : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const configEvery = Duration(minutes: 30);
  static const pushEvery = Duration(minutes: 15);
  static const _pushChunk = 500; // server limit (api/presence/push.php)
  static const _logSize = 300;

  Fix? _lastFix;
  int _lastCheckAt = 0;
  int _lastPushAt = 0;
  int _lastConfigAt = 0;
  bool _checking = false;
  Future<void>? _pushing;

  /// A fix from a position stream, used by the next check.
  void offerFix(Fix fix) => _lastFix = fix;

  /// One detection round. Unless [force]d, at most one per interval: a
  /// timer and position updates may both ask.
  Future<CheckOutcome> check({bool force = false}) async {
    final settings = await PresenceSettings.load(db);
    final loggedIn = await isLoggedIn();
    if (!settings.active(loggedIn: loggedIn)) {
      await closeAll();
      if (loggedIn) await push();
      return const CheckOutcome(active: false);
    }
    final now = clock();
    // A little slack, so a timer tick firing early isn't skipped.
    final minGap = settings.intervalMinutes * 60 * 1000 - 15 * 1000;
    if (_checking || (!force && now - _lastCheckAt < minGap)) {
      return const CheckOutcome(active: true);
    }
    _checking = true;
    try {
      return await _run(settings, now);
    } finally {
      _checking = false;
    }
  }

  Future<CheckOutcome> _run(PresenceSettings settings, int now) async {
    _lastCheckAt = now;
    final mode = settings.mode;
    final previous = await readLast(db);

    // Detection stopped for a while (app closed, phone off, suspended):
    // the log says so, the stays are closed by [step] at their last
    // detection.
    final interval = settings.intervalMinutes * 60 * 1000;
    if (previous != null && now - previous.atMs > 2 * interval + 60 * 1000) {
      await log(
        'Nessun controllo per ${_minutes(now - previous.atMs)} '
        '(dalle ${_hm(previous.atMs)})',
      );
    }

    if (PresenceSensors.needsLocation(mode)) {
      final problem = await locationProblem(request: interactive);
      if (problem != null) {
        final last = LastCheck(atMs: now, problem: problem);
        if (previous?.problem != problem) await log(problem);
        await _saveLast(last);
        return CheckOutcome(active: true, ran: true, last: last);
      }
    }

    final wifi = mode.usesWifi ? await readWifi() : null;
    Fix? fix;
    if (mode.usesGps) {
      fix = _lastFix;
      if (fix == null || now - fix.atMs > maxFixAgeMs ~/ 2) {
        fix = await readFix() ?? fix;
        _lastFix = fix;
      }
    }
    final obs = Observation(atMs: now, fix: fix, wifi: wifi);
    final changes = await _record(settings, obs);

    final inside = [
      for (final s in await db.presencesDao.getOpen()) s.placeName,
    ];
    final last = LastCheck(
      atMs: now,
      wifiRead: mode.usesWifi,
      wifi: wifi,
      gpsRead: mode.usesGps,
      gpsAccuracyM: fix != null && now - fix.atMs <= maxFixAgeMs
          ? fix.accuracyM
          : null,
      inside: inside,
    );
    await _saveLast(last);
    for (final c in changes) {
      await log(c);
    }

    if (changes.isNotEmpty || now - _lastPushAt > pushEvery.inMilliseconds) {
      await push();
    }
    if (now - _lastConfigAt > configEvery.inMilliseconds) {
      await refreshConfig().catchError((Object e) {
        debugPrint('[Presence] config refresh failed: $e');
        return settings.config;
      });
    }
    return CheckOutcome(active: true, ran: true, last: last);
  }

  /// Applies [obs] to the stored stays; describes each entry and exit.
  Future<List<String>> _record(
    PresenceSettings settings,
    Observation obs,
  ) async {
    final places = {for (final p in settings.config.places) p.id: p};
    final open = await db.presencesDao.getOpen();
    final names = {for (final s in open) s.id: s.placeName};
    final results = {
      for (final p in places.values) p.id: evaluate(p, settings.mode, obs),
    };
    final changes = step(
      open: [for (final s in open) OpenStay(s.id, s.placeId, s.lastSeenAt)],
      results: results,
      nowMs: obs.atMs,
      graceMs: exitGraceFor(settings.intervalMinutes),
    );
    final events = <String>[];
    await db.transaction(() async {
      for (final c in changes) {
        switch (c) {
          case StayEnter(:final placeId, :final method, :final at):
            await db.presencesDao.insertPresence(
              PresencesCompanion.insert(
                id: const Uuid().v4(),
                placeId: placeId,
                placeName: places[placeId]!.name,
                method: method,
                enteredAt: at,
                lastSeenAt: at,
              ),
            );
            events.add('Entrata: ${places[placeId]!.name} ($method)');
          case StaySeen(:final stayId, :final at):
            await db.presencesDao.markSeen(stayId, at);
          case StayExit(:final stayId, :final at):
            await db.presencesDao.closeStay(stayId, at);
            events.add(
              'Uscita: ${names[stayId] ?? '?'} alle ${_hm(at)} '
              '(ultimo rilevamento)',
            );
        }
      }
    });
    return events;
  }

  /// Closes every open stay at its last detection.
  Future<void> closeAll() async {
    for (final s in await db.presencesDao.getOpen()) {
      await db.presencesDao.closeStay(s.id, s.lastSeenAt);
      await log(
        'Uscita: ${s.placeName} alle ${_hm(s.lastSeenAt)} '
        '(rilevamento spento)',
      );
    }
  }

  /// Downloads settings and places into the cache. Throws on errors.
  Future<PresenceConfig> refreshConfig() async {
    final config = PresenceConfig.fromJson(await api.get('/presence/config'));
    _lastConfigAt = clock();
    await db.settingsDao.setValue(
      PresenceKeys.config,
      jsonEncode(config.toJson()),
    );
    return config;
  }

  /// Sends unsynced stays. Errors are left to the next round.
  Future<void> push() =>
      _pushing ??= _pushNow().whenComplete(() => _pushing = null);

  Future<void> _pushNow() async {
    try {
      final rows = await db.presencesDao.getUnsynced();
      final device = kIsWeb ? 'web' : defaultTargetPlatform.name;
      for (var i = 0; i < rows.length; i += _pushChunk) {
        final batch = rows.sublist(i, min(i + _pushChunk, rows.length));
        final result = await api.post('/presence/push', {
          'presences': [
            for (final p in batch)
              {
                'client_id': p.id,
                'place_client_id': p.placeId,
                'place_name': p.placeName,
                'device': device,
                'method': p.method,
                'entered_at': p.enteredAt,
                'exited_at': p.exitedAt,
                'last_seen_at': p.lastSeenAt,
              },
          ],
        });
        final byId = {for (final p in batch) p.id: p};
        for (final s in (result['synced_presences'] as List)) {
          final m = s as Map<String, dynamic>;
          final pushed = byId[m['client_id']];
          if (pushed != null) {
            await db.presencesDao.markSynced(pushed, m['server_id'] as int);
          }
        }
      }
      _lastPushAt = clock();
    } catch (e) {
      debugPrint('[Presence] push failed: $e');
    }
  }

  // ── Status and log ───────────────────────────────────────────────────────

  Future<void> _saveLast(LastCheck last) =>
      db.settingsDao.setValue(PresenceKeys.last, jsonEncode(last.toJson()));

  static Future<LastCheck?> readLast(AppDatabase db) async {
    final raw = await db.settingsDao.getValue(PresenceKeys.last);
    if (raw == null) return null;
    try {
      return LastCheck.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Appends to the diagnostic log (the most recent [_logSize] entries).
  Future<void> log(String message) async {
    final entries = await readLog(db);
    final kept = [
      PresenceLogEntry(clock(), message),
      ...entries,
    ].take(_logSize);
    await db.settingsDao.setValue(
      PresenceKeys.log,
      jsonEncode([
        for (final e in kept) {'t': e.atMs, 'm': e.message},
      ]),
    );
  }

  /// Newest first.
  static Future<List<PresenceLogEntry>> readLog(AppDatabase db) async {
    final raw = await db.settingsDao.getValue(PresenceKeys.log);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          PresenceLogEntry(((e as Map)['t'] as num).toInt(), e['m'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String _hm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  static String _minutes(int ms) {
    final m = ms ~/ 60000;
    return m < 60
        ? '$m min'
        : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }
}
