import 'dart:async';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show TableUpdate;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import 'presence_engine.dart';
import 'presence_logic.dart';
import 'presence_sensors.dart';
import 'presence_service.dart';

@immutable
class PresenceState {
  final PresenceSettings settings;
  final bool loggedIn;

  /// Detection is running (on Android: the background service).
  final bool running;

  /// Why detection can't run (permissions, location off…).
  final String? problem;
  final LastCheck? last;

  /// Android: the system may suspend the app to save battery.
  final bool batteryOptimized;

  /// Android: location allowed only while in use, so the service can't
  /// restart by itself after a reboot.
  final bool needsBackgroundLocation;

  const PresenceState({
    this.settings = const PresenceSettings(),
    this.loggedIn = false,
    this.running = false,
    this.problem,
    this.last,
    this.batteryOptimized = false,
    this.needsBackgroundLocation = false,
  });

  PresenceConfig get config => settings.config;
  bool get enabled => settings.enabled;
  TrackingMode get mode => settings.mode;
  int get intervalMinutes => settings.intervalMinutes;
  bool get available => loggedIn && config.policy != PresencePolicy.off;

  PresenceState copyWith({
    PresenceSettings? settings,
    bool? loggedIn,
    bool? running,
    String? Function()? problem,
    LastCheck? last,
    bool? batteryOptimized,
    bool? needsBackgroundLocation,
  }) => PresenceState(
    settings: settings ?? this.settings,
    loggedIn: loggedIn ?? this.loggedIn,
    running: running ?? this.running,
    problem: problem != null ? problem() : this.problem,
    last: last ?? this.last,
    batteryOptimized: batteryOptimized ?? this.batteryOptimized,
    needsBackgroundLocation:
        needsBackgroundLocation ?? this.needsBackgroundLocation,
  );
}

final presenceProvider = NotifierProvider<PresenceController, PresenceState>(
  PresenceController.new,
);

/// Stays recorded on this device, most recent first.
final recentPresencesProvider = StreamProvider<List<Presence>>(
  (ref) => ref.watch(appDatabaseProvider).presencesDao.watchRecent(),
);

/// Diagnostic log, newest first. Refreshed after each check.
final presenceLogProvider = FutureProvider<List<PresenceLogEntry>>((ref) {
  ref.watch(presenceProvider.select((s) => s.last?.atMs));
  return PresenceEngine.readLog(ref.read(appDatabaseProvider));
});

/// Presence detection, from the app's side.
///
/// On Android detection runs in a background service
/// (presence_service.dart) that survives the app being closed; this
/// controller starts and stops it and shows its state. Elsewhere it runs
/// here, while the app is open (or in the background, where the platform
/// allows it).
class PresenceController extends Notifier<PresenceState> {
  static bool get _useService =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  late final PresenceEngine _engine;
  Future<void>? _loaded;

  // In-app detection (not Android).
  StreamSubscription<Fix>? _positions;
  Timer? _timer;
  (TrackingMode, int)? _runningLocal;

  AppDatabase get _db => ref.read(appDatabaseProvider);

  @override
  PresenceState build() {
    _engine = PresenceEngine(
      db: _db,
      api: ref.read(apiClientProvider),
      interactive: true,
      isLoggedIn: () async =>
          ref.read(authNotifierProvider).valueOrNull?.status ==
          AuthStatus.authenticated,
    );
    ref.onDispose(_stopLocal);
    ref.listen(authNotifierProvider, (prev, next) {
      final was = prev?.valueOrNull?.status == AuthStatus.authenticated;
      final now = next.valueOrNull?.status == AuthStatus.authenticated;
      if (was != now) _onAuthChanged(now);
    });
    if (_useService) {
      FlutterForegroundTask.addTaskDataCallback(_onServiceData);
      ref.onDispose(
        () => FlutterForegroundTask.removeTaskDataCallback(_onServiceData),
      );
    }
    _loaded = _load();
    return const PresenceState();
  }

  /// Resolves once the stored settings are loaded.
  Future<void> get ready => _loaded ?? Future.value();

  Future<void> _load() async {
    final auth = await ref
        .read(authNotifierProvider.future)
        .catchError(
          (Object _) => const AuthState(status: AuthStatus.unauthenticated),
        );
    state = state.copyWith(
      settings: await PresenceSettings.load(_db),
      loggedIn: auth.status == AuthStatus.authenticated,
      last: await PresenceEngine.readLast(_db),
    );
    await _apply();
    if (state.loggedIn) await refreshConfig().catchError((Object _) {});
  }

  Future<void> _onAuthChanged(bool loggedIn) async {
    await ready;
    state = state.copyWith(loggedIn: loggedIn);
    if (loggedIn) {
      await refreshConfig().catchError((Object _) {});
    } else {
      // Another account may log in next: its settings come from the server.
      await _db.settingsDao.deleteValue(PresenceKeys.config);
      await _reloadSettings();
      await _apply();
    }
  }

  Future<void> _reloadSettings() async =>
      state = state.copyWith(settings: await PresenceSettings.load(_db));

  // ── Public API (presence screen, lifecycle) ─────────────────────────────

  /// Downloads settings and places. Throws on network errors (the cached
  /// copy stays in use).
  Future<void> refreshConfig() async {
    await _engine.refreshConfig();
    await _reloadSettings();
    await _apply();
  }

  Future<void> setEnabled(bool enabled) async {
    await ready;
    await _db.settingsDao.setValue(PresenceKeys.enabled, enabled ? '1' : '0');
    await _engine.log(
      enabled ? 'Rilevamento acceso' : 'Rilevamento spento dall\'utente',
    );
    await _reloadSettings();
    state = state.copyWith(problem: () => null);
    await _apply();
  }

  Future<void> setMode(TrackingMode mode) async {
    await _db.settingsDao.setValue(PresenceKeys.mode, mode.wire);
    await _reloadSettings();
    await _apply();
  }

  Future<void> setInterval(int minutes) async {
    await _db.settingsDao.setValue(
      PresenceKeys.interval,
      '${PresenceSettings.validInterval(minutes)}',
    );
    await _reloadSettings();
    await _apply();
  }

  /// Back in the foreground: catch up with settings, permissions and what
  /// the service did meanwhile.
  Future<void> onResume() async {
    await ready;
    if (!state.loggedIn) return;
    await refreshConfig().catchError((Object _) {});
  }

  /// Android: asks to be left out of battery optimization, so the system
  /// doesn't suspend detection.
  Future<void> requestBatteryExemption() async {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    await _refreshStatus();
  }

  /// Android: the app's settings, where location can be set to "Consenti
  /// sempre".
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  /// Creates or updates one of the user's places (policy "user"), then
  /// reloads the places. [id] null creates a new place.
  Future<void> savePlace({
    String? id,
    required String name,
    double? latitude,
    double? longitude,
    required int radiusM,
    required List<String> wifi,
  }) async {
    await _postPlace({
      'client_id': id ?? const Uuid().v4(),
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'radius_m': radiusM,
      'wifi': wifi,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> deletePlace(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _postPlace({'client_id': id, 'updated_at': now, 'deleted_at': now});
  }

  Future<void> _postPlace(Map<String, dynamic> place) async {
    await ref.read(apiClientProvider).post('/presence/places', {
      'places': [place],
    });
    await refreshConfig();
  }

  /// The message to show for a failed place save or config download.
  static String errorMessage(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        return data['error'] as String;
      }
      if (e.response == null) return 'Server non raggiungibile.';
      return 'Errore del server (HTTP ${e.response?.statusCode}).';
    }
    return '$e';
  }

  // ── Running detection ────────────────────────────────────────────────────

  /// Starts, updates or stops detection to match the settings.
  Future<void> _apply() async {
    final s = state.settings;
    if (!s.active(loggedIn: state.loggedIn)) {
      if (_useService) {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      } else {
        _stopLocal();
      }
      await _engine.closeAll();
      if (state.loggedIn) unawaited(_engine.push());
      state = state.copyWith(running: false);
      await _refreshStatus();
      return;
    }

    if (PresenceSensors.needsLocation(s.mode)) {
      final problem = await PresenceSensors.locationProblem(request: true);
      if (problem != null) {
        if (_useService && await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
        _stopLocal();
        state = state.copyWith(running: false, problem: () => problem);
        return;
      }
    } else if (s.mode.usesWifi && !PresenceSensors.wifiSupported) {
      _stopLocal();
      state = state.copyWith(
        running: false,
        problem: () =>
            'Su questa piattaforma la rete Wi-Fi non è leggibile: '
            'scegli una modalità con il GPS.',
      );
      return;
    }

    state = state.copyWith(problem: () => null);
    if (_useService) {
      await _startService(s);
    } else {
      await _startLocal(s);
    }
    await _refreshStatus();
  }

  Future<void> _startService(PresenceSettings s) async {
    final restartOnBoot = await PresenceSensors.hasBackgroundLocation();
    PresenceService.init(
      intervalMinutes: s.intervalMinutes,
      restartOnBoot: restartOnBoot,
    );
    final ServiceRequestResult result;
    if (await FlutterForegroundTask.isRunningService) {
      result = await FlutterForegroundTask.updateService(
        foregroundTaskOptions: PresenceService.options(
          intervalMinutes: s.intervalMinutes,
          restartOnBoot: restartOnBoot,
        ),
      );
      // Settings may have changed: check with them now.
      FlutterForegroundTask.sendDataToTask(PresenceService.checkNow);
    } else {
      result = await PresenceService.start();
    }
    if (result is ServiceRequestFailure) {
      await _engine.log('Avvio del servizio non riuscito: ${result.error}');
      state = state.copyWith(
        problem: () => 'Impossibile avviare il rilevamento in background.',
      );
    }
  }

  Future<void> _startLocal(PresenceSettings s) async {
    final key = (s.mode, s.intervalMinutes);
    if (_runningLocal == key) {
      await _checkLocal(force: true); // the places may have changed
      return;
    }
    _stopLocal();
    if (PresenceSensors.needsLocation(s.mode)) {
      _positions = PresenceSensors.positions(s.mode, s.intervalMinutes).listen((
        fix,
      ) {
        _engine.offerFix(fix);
        unawaited(_checkLocal());
      }, onError: (Object e) => debugPrint('[Presence] position stream: $e'));
    }
    _timer = Timer.periodic(
      Duration(minutes: s.intervalMinutes),
      (_) => unawaited(_checkLocal()),
    );
    _runningLocal = key;
    state = state.copyWith(running: true);
    await _checkLocal(force: true);
  }

  Future<void> _checkLocal({bool force = false}) async {
    try {
      final outcome = await _engine.check(force: force);
      if (outcome.ran && outcome.last != null) {
        state = state.copyWith(last: outcome.last);
      }
    } catch (e) {
      debugPrint('[Presence] detection failed: $e');
    }
  }

  void _stopLocal() {
    _positions?.cancel();
    _positions = null;
    _timer?.cancel();
    _timer = null;
    _runningLocal = null;
  }

  /// The service wrote to the database: show it.
  void _onServiceData(Object data) {
    if (data != PresenceService.changed) return;
    // Its writes come from another connection: tell this one's queries.
    _db.notifyUpdates({TableUpdate.onTable(_db.presences)});
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final last = await PresenceEngine.readLast(_db);
    if (!_useService) {
      state = state.copyWith(last: last, running: _runningLocal != null);
      return;
    }
    state = state.copyWith(
      last: last,
      running: await FlutterForegroundTask.isRunningService,
      batteryOptimized:
          !await FlutterForegroundTask.isIgnoringBatteryOptimizations,
      needsBackgroundLocation:
          state.settings.active(loggedIn: state.loggedIn) &&
          PresenceSensors.needsLocation(state.mode) &&
          !await PresenceSensors.hasBackgroundLocation(),
    );
  }
}
