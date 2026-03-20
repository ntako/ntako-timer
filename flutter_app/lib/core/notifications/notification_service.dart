import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps flutter_local_notifications.
/// All public methods are no-ops on web (kIsWeb).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    if (kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    // Android 13+ (API 33): request POST_NOTIFICATIONS at runtime.
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  /// Show a persistent ongoing notification while the timer is running.
  static Future<void> showOngoing({
    required int id,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ntako_timer_ongoing',
          'Timer in corso',
          channelDescription: 'Mostra il timer attivo nella barra di stato',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }

  /// Show an alert notification that plays sound (used for alarms and break end).
  /// Pass [sound] = false to suppress sound (when alarmVolume == 0).
  static Future<void> showAlert({
    required int id,
    required String title,
    required String body,
    bool sound = true,
  }) async {
    if (kIsWeb) return;
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? 'ntako_timer_alert' : 'ntako_timer_alert_silent',
          sound ? 'Allarme timer' : 'Allarme timer (silenzioso)',
          channelDescription: 'Notifiche allarme e fine pausa',
          importance: sound ? Importance.high : Importance.low,
          priority: sound ? Priority.high : Priority.low,
          playSound: sound,
          ongoing: false,
          autoCancel: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: sound,
        ),
      ),
    );
  }

  static Future<void> cancel(int id) async {
    if (kIsWeb) return;
    await _plugin.cancel(id);
  }
}
