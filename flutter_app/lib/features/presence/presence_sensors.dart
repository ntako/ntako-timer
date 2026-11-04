import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'presence_logic.dart';

/// Location and Wi-Fi readings, per platform. Every method copes with
/// what the platform lacks: null means "not available here".
class PresenceSensors {
  const PresenceSensors._();

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Wi-Fi can be read on this platform (not in a browser).
  static bool get wifiSupported =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.macOS;

  /// Whether [mode] needs location access: for GPS, and on phones also for
  /// the Wi-Fi name, which Android and iOS treat as location data.
  static bool needsLocation(TrackingMode mode) =>
      mode.usesGps || (_mobile && mode.usesWifi);

  /// Null when location can be used, otherwise a message for the user.
  /// With [request] a missing permission is asked for (needs the app on
  /// screen: never from the background service).
  static Future<String?> locationProblem({required bool request}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return 'Localizzazione disattivata: attivala nelle impostazioni del dispositivo.';
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && request) {
        permission = await Geolocator.requestPermission();
      }
      return switch (permission) {
        LocationPermission.denied =>
          'Permesso posizione negato: serve per riconoscere i luoghi.',
        LocationPermission.deniedForever =>
          'Permesso posizione negato: abilitalo dalle impostazioni dell\'app.',
        _ => null,
      };
    } catch (e) {
      debugPrint('[Presence] location access check failed: $e');
      return 'Posizione non disponibile su questo dispositivo.';
    }
  }

  /// Asks for location access if needed (see [locationProblem]).
  static Future<String?> ensureLocationAccess() =>
      locationProblem(request: true);

  /// Location allowed also in the background ("Consenti sempre"): needed
  /// for the Android service to restart on its own after a reboot.
  static Future<bool> hasBackgroundLocation() async {
    try {
      return await Geolocator.checkPermission() == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// Continuous position updates, for detection running inside the app
  /// (not Android, where a background service checks on its own). On
  /// Android a fix comes every [intervalMinutes]; elsewhere the platform
  /// decides, and the engine ignores the extra ones.
  static Stream<Fix> positions(TrackingMode mode, int intervalMinutes) {
    final accuracy = mode.usesGps
        ? LocationAccuracy.high
        : LocationAccuracy.low;
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: accuracy,
        intervalDuration: Duration(minutes: intervalMinutes),
      );
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: accuracy,
        allowBackgroundLocationUpdates: true,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    } else {
      settings = LocationSettings(accuracy: accuracy);
    }
    return Geolocator.getPositionStream(locationSettings: settings).map(_fix);
  }

  /// One fresh fix, or null if none comes in time.
  static Future<Fix?> currentFix() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return _fix(p);
    } catch (e) {
      debugPrint('[Presence] position unavailable: $e');
      return null;
    }
  }

  /// The connected network; [WifiInfo.none] if not connected, null if
  /// Wi-Fi can't be read here.
  static Future<WifiInfo?> currentWifi() async {
    if (!wifiSupported) return null;
    try {
      final info = NetworkInfo();
      var ssid = await info.getWifiName();
      var bssid = await info.getWifiBSSID();
      // Android quotes the name, and reports placeholders when the
      // network is unknown.
      if (ssid != null) {
        ssid = ssid.replaceAll(RegExp(r'^"|"$'), '');
        if (ssid.isEmpty || ssid == '<unknown ssid>') ssid = null;
      }
      if (bssid != null &&
          (bssid.isEmpty || normalizeBssid(bssid) == '02:00:00:00:00:00')) {
        bssid = null;
      }
      return WifiInfo(ssid: ssid, bssid: bssid);
    } catch (e) {
      debugPrint('[Presence] Wi-Fi unavailable: $e');
      return null;
    }
  }

  static Fix _fix(Position p) => Fix(
    p.latitude,
    p.longitude,
    p.accuracy,
    p.timestamp.millisecondsSinceEpoch,
  );
}
