import 'dart:math';

/// Presence detection ("badge"): pure rules, no I/O. The settings and the
/// places come from the backend (backend/lib/Presence.php).

/// Who decides the mode and the places.
enum PresencePolicy {
  /// No detection.
  off,

  /// Set by the admin: devices only detect.
  admin,

  /// Each device picks its mode, the user manages their own places.
  user;

  static PresencePolicy parse(Object? v) =>
      values.firstWhere((p) => p.name == v, orElse: () => off);
}

enum TrackingMode {
  gps('gps', 'Solo GPS'),
  wifi('wifi', 'Solo Wi-Fi'),
  gpsAndWifi('gps_and_wifi', 'GPS e Wi-Fi (entrambi)'),
  gpsOrWifi('gps_or_wifi', 'GPS o Wi-Fi (almeno uno)');

  const TrackingMode(this.wire, this.label);

  /// Name in the API.
  final String wire;
  final String label;

  bool get usesGps => this != wifi;
  bool get usesWifi => this != gps;

  static TrackingMode? tryParse(Object? v) {
    for (final m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

class Place {
  /// The place's client_id on the server.
  final String id;
  final String name;
  final double? latitude;
  final double? longitude;

  /// Detection radius in metres, chosen to include the GPS error.
  final int radiusM;

  /// SSIDs (network names) and BSSIDs (access point addresses).
  final List<String> wifi;

  /// Shared by every user of the platform, edited only by the admin.
  final bool platform;
  final bool editable;
  final int updatedAt;

  /// Color slot in reports (1–8, 0 = neutral), assigned by the server.
  final int slot;

  const Place({
    required this.id,
    required this.name,
    this.latitude,
    this.longitude,
    this.radiusM = 100,
    this.wifi = const [],
    this.platform = false,
    this.editable = false,
    this.updatedAt = 0,
    this.slot = 0,
  });

  bool get hasPosition => latitude != null && longitude != null;
  bool get hasWifi => wifi.isNotEmpty;

  factory Place.fromJson(Map<String, dynamic> m) => Place(
    id: m['client_id'] as String,
    name: m['name'] as String,
    latitude: (m['latitude'] as num?)?.toDouble(),
    longitude: (m['longitude'] as num?)?.toDouble(),
    radiusM: (m['radius_m'] as num?)?.toInt() ?? 100,
    wifi: [for (final w in (m['wifi'] as List? ?? const [])) w as String],
    platform: m['scope'] == 'platform',
    editable: m['editable'] == true,
    updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
    slot: (m['slot'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'client_id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'radius_m': radiusM,
    'wifi': wifi,
    'scope': platform ? 'platform' : 'user',
    'editable': editable,
    'updated_at': updatedAt,
    'slot': slot,
  };
}

class PresenceConfig {
  final PresencePolicy policy;

  /// The admin's mode; with policy [PresencePolicy.user] only a suggestion.
  final TrackingMode mode;
  final bool canEdit;
  final List<Place> places;

  const PresenceConfig({
    this.policy = PresencePolicy.off,
    this.mode = TrackingMode.gpsOrWifi,
    this.canEdit = false,
    this.places = const [],
  });

  static const disabled = PresenceConfig();

  factory PresenceConfig.fromJson(Map<String, dynamic> m) => PresenceConfig(
    policy: PresencePolicy.parse(m['policy']),
    mode: TrackingMode.tryParse(m['mode']) ?? TrackingMode.gpsOrWifi,
    canEdit: m['can_edit'] == true,
    places: [
      for (final p in (m['places'] as List? ?? const []))
        Place.fromJson(p as Map<String, dynamic>),
    ],
  );

  Map<String, dynamic> toJson() => {
    'policy': policy.name,
    'mode': mode.wire,
    'can_edit': canEdit,
    'places': [for (final p in places) p.toJson()],
  };
}

/// A position fix.
class Fix {
  final double latitude;
  final double longitude;

  /// Estimated error, metres.
  final double accuracyM;
  final int atMs;

  const Fix(this.latitude, this.longitude, this.accuracyM, this.atMs);
}

/// The Wi-Fi network the device is connected to. Both null: not connected.
class WifiInfo {
  final String? ssid;
  final String? bssid;

  const WifiInfo({this.ssid, this.bssid});

  static const none = WifiInfo();

  bool get connected => ssid != null || bssid != null;
}

/// What the device knows at one moment. Null = not available (no fix,
/// Wi-Fi not readable on this platform or without permission).
class Observation {
  final int atMs;
  final Fix? fix;
  final WifiInfo? wifi;

  const Observation({required this.atMs, this.fix, this.wifi});
}

enum Evidence { match, miss, unknown }

class PlaceMatch {
  final Evidence evidence;

  /// What matched: 'gps', 'wifi' or 'gps+wifi' (empty unless a match).
  final String method;

  const PlaceMatch(this.evidence, [this.method = '']);

  static const miss = PlaceMatch(Evidence.miss);
  static const unknown = PlaceMatch(Evidence.unknown);
}

/// A fix older than this tells nothing about where the device is now.
const maxFixAgeMs = 3 * 60 * 1000;

/// Accuracy needed to say "inside" when the radius is smaller than this.
const minUsableAccuracyM = 100.0;

/// Great-circle distance in metres.
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

/// "Aa-Bb-..." → "aa:bb:...", for comparing BSSIDs.
String normalizeBssid(String s) => s.trim().toLowerCase().replaceAll('-', ':');

final _bssidRe = RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2}){5}$');

bool looksLikeBssid(String s) => _bssidRe.hasMatch(normalizeBssid(s));

/// GPS evidence for [place]; null if the place has no position.
///
/// Inside when the fix is within the radius and precise enough to tell;
/// outside only when even the error margin can't reach the radius.
Evidence? gpsEvidence(Place place, Fix? fix, int nowMs) {
  if (!place.hasPosition) return null;
  if (fix == null || nowMs - fix.atMs > maxFixAgeMs) return Evidence.unknown;
  final d = distanceM(
    fix.latitude,
    fix.longitude,
    place.latitude!,
    place.longitude!,
  );
  if (d <= place.radiusM &&
      fix.accuracyM <= max(place.radiusM.toDouble(), minUsableAccuracyM)) {
    return Evidence.match;
  }
  if (d - fix.accuracyM > place.radiusM) return Evidence.miss;
  return Evidence.unknown;
}

/// Wi-Fi evidence for [place]; null if the place has no networks.
Evidence? wifiEvidence(Place place, WifiInfo? wifi) {
  if (!place.hasWifi) return null;
  if (wifi == null) return Evidence.unknown;
  final bssid = wifi.bssid == null ? null : normalizeBssid(wifi.bssid!);
  for (final w in place.wifi) {
    if (looksLikeBssid(w)) {
      if (bssid != null && normalizeBssid(w) == bssid) return Evidence.match;
    } else if (wifi.ssid != null && w == wifi.ssid) {
      return Evidence.match;
    }
  }
  return Evidence.miss;
}

/// Whether the device is in [place] according to [mode].
///
/// The "and"/"or" modes apply to what the place defines: a place with only
/// a position is detected by GPS alone in both. A place lacking what a
/// single-source mode needs is never detected.
PlaceMatch evaluate(Place place, TrackingMode mode, Observation obs) {
  final gps = mode.usesGps ? gpsEvidence(place, obs.fix, obs.atMs) : null;
  final wifi = mode.usesWifi ? wifiEvidence(place, obs.wifi) : null;
  final checks = [?gps, ?wifi];
  if (checks.isEmpty) return PlaceMatch.miss;

  final method = [
    if (gps == Evidence.match) 'gps',
    if (wifi == Evidence.match) 'wifi',
  ].join('+');

  final all = mode == TrackingMode.gpsAndWifi;
  if (all) {
    if (checks.contains(Evidence.miss)) return PlaceMatch.miss;
    if (checks.every((e) => e == Evidence.match)) {
      return PlaceMatch(Evidence.match, method);
    }
    return PlaceMatch.unknown;
  }
  if (checks.contains(Evidence.match)) {
    return PlaceMatch(Evidence.match, method);
  }
  if (checks.every((e) => e == Evidence.miss)) return PlaceMatch.miss;
  return PlaceMatch.unknown;
}

/// A stay not closed yet.
class OpenStay {
  final String id;
  final String placeId;
  final int lastSeenAt;

  const OpenStay(this.id, this.placeId, this.lastSeenAt);
}

sealed class StayChange {
  const StayChange();
}

class StayEnter extends StayChange {
  final String placeId;
  final String method;
  final int at;

  const StayEnter(this.placeId, this.method, this.at);
}

/// Still inside at [at].
class StaySeen extends StayChange {
  final String stayId;
  final int at;

  const StaySeen(this.stayId, this.at);
}

/// Left; [at] is the last moment the device was seen inside.
class StayExit extends StayChange {
  final String stayId;
  final int at;

  const StayExit(this.stayId, this.at);
}

/// After leaving, misses for this long confirm the exit: GPS jitter at the
/// edge of the radius or a Wi-Fi drop must not split a stay.
const exitGraceMs = 3 * 60 * 1000;

/// How often a device can check where it is, in minutes. At most 10: a
/// stay whose device is silent for [staleMs] counts as ended, and a check
/// plus the upload delay must stay well within it.
const checkIntervals = [1, 2, 5, 10];

/// [exitGraceMs], but always at least two missed checks.
int exitGraceFor(int intervalMinutes) =>
    max(exitGraceMs, 2 * intervalMinutes * 60 * 1000);

/// Without any evidence for this long (or between two checks: device off,
/// app closed) a stay is closed at its last detection.
const staleMs = 30 * 60 * 1000;

/// One detection round: what happens to the open stays and which new ones
/// start, given the evaluation of each current place.
List<StayChange> step({
  required List<OpenStay> open,
  required Map<String, PlaceMatch> results,
  required int nowMs,
  int graceMs = exitGraceMs,
}) {
  final changes = <StayChange>[];
  final inside = <String>{};
  for (final stay in open) {
    final r = results[stay.placeId];
    final silent = nowMs - stay.lastSeenAt;
    final stillIn = switch (r?.evidence) {
      _ when silent > staleMs => false,
      null => false, // place removed or detection turned off
      Evidence.match => true,
      Evidence.miss => silent < graceMs,
      Evidence.unknown => true,
    };
    if (!stillIn) {
      changes.add(StayExit(stay.id, stay.lastSeenAt));
    } else {
      inside.add(stay.placeId);
      if (r!.evidence == Evidence.match) {
        changes.add(StaySeen(stay.id, nowMs));
      }
    }
  }
  for (final MapEntry(key: placeId, value: r) in results.entries) {
    if (r.evidence == Evidence.match && !inside.contains(placeId)) {
      changes.add(StayEnter(placeId, r.method, nowMs));
    }
  }
  return changes;
}
