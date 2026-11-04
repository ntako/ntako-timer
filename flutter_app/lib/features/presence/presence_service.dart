import 'dart:async';
import 'dart:ui';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';
import 'presence_engine.dart';

/// Android background service for presence detection.
///
/// A foreground service (type "location", with its notification) with its
/// own Flutter engine: unlike detection inside the app, it goes on when the
/// app is closed from the recent apps, and restarts after a reboot or an
/// app update. It opens the app's database itself; the app starts and stops
/// it (PresenceController) and gets a message after each check.
abstract final class PresenceService {
  static const serviceId = 4173;

  /// Messages between the app and the service.
  static const checkNow = 'check';
  static const changed = 'changed';

  static void init({
    required int intervalMinutes,
    required bool restartOnBoot,
  }) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'workadoro_presence',
        channelName: 'Rilevamento presenze',
        channelDescription:
            'Indica che il rilevamento presenze è attivo e dove ti trovi',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: options(
        intervalMinutes: intervalMinutes,
        restartOnBoot: restartOnBoot,
      ),
    );
  }

  static ForegroundTaskOptions options({
    required int intervalMinutes,
    required bool restartOnBoot,
  }) => ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.repeat(intervalMinutes * 60 * 1000),
    // A location service may start at boot only with "Consenti sempre".
    autoRunOnBoot: restartOnBoot,
    autoRunOnMyPackageReplaced: true,
    allowWakeLock: true,
    allowWifiLock: true,
    stopWithTask: false,
  );

  static Future<ServiceRequestResult> start() =>
      FlutterForegroundTask.startService(
        serviceId: serviceId,
        serviceTypes: const [ForegroundServiceTypes.location],
        notificationTitle: 'Rilevamento presenze attivo',
        notificationText: 'Avvio…',
        notificationInitialRoute: '/presence',
        callback: presenceServiceCallback,
      );
}

@pragma('vm:entry-point')
void presenceServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_PresenceTaskHandler());
}

class _PresenceTaskHandler extends TaskHandler {
  AppDatabase? _db;
  PresenceEngine? _engine;
  Future<void>? _running;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Plugins with a Dart side (geolocator…) in this engine too.
    DartPluginRegistrant.ensureInitialized();
    final db = _db = AppDatabase();
    final storage = SecureStorageService();
    final engine = _engine = PresenceEngine(
      db: db,
      api: ApiClient(
        storage,
        storedBaseUrl: db.settingsDao.getValue(ApiClient.baseUrlSettingsKey),
      ),
      isLoggedIn: () async {
        try {
          return await storage.isLoggedIn.timeout(const Duration(seconds: 5));
        } catch (_) {
          return false;
        }
      },
    );
    await engine.log(
      starter == TaskStarter.system
          ? 'Servizio riavviato dal sistema (riavvio o aggiornamento)'
          : 'Servizio avviato',
    );
    await _check(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_check());

  @override
  void onReceiveData(Object data) {
    if (data == PresenceService.checkNow) unawaited(_check(force: true));
  }

  Future<void> _check({bool force = false}) =>
      _running ??= _checkNow(force).whenComplete(() => _running = null);

  Future<void> _checkNow(bool force) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      final outcome = await engine.check(force: force);
      if (!outcome.active) {
        // Turned off, logged out or nothing to detect: nothing to keep.
        await FlutterForegroundTask.stopService();
        return;
      }
      final last = outcome.last;
      if (outcome.ran && last != null) {
        await FlutterForegroundTask.updateService(
          notificationText:
              last.problem ??
              (last.inside.isEmpty
                  ? 'Fuori dai luoghi noti · controllo alle ${_hm(last.atMs)}'
                  : 'Sei in: ${last.inside.join(', ')}'),
        );
      }
      FlutterForegroundTask.sendDataToMain(PresenceService.changed);
    } catch (e) {
      await engine.log('Errore nel controllo: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _running;
    await _engine?.log(
      isTimeout
          ? 'Servizio fermato dal sistema (tempo scaduto)'
          : 'Servizio fermato',
    );
    await _db?.close();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/presence');

  static String _hm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}
