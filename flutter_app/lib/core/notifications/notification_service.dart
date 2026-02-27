import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../../features/timer/timer_state.dart';

/// Wraps flutter_local_notifications.
/// All public methods are no-ops on web (kIsWeb).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    if (kIsWeb) return;

    tz.initializeTimeZones();

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

  /// Schedule a notification at [endTime] indicating that [phase] is over.
  static Future<void> scheduleTimerEnd({
    required int id,
    required DateTime endTime,
    required TimerPhase phase,
  }) async {
    if (kIsWeb) return;

    final title = switch (phase) {
      TimerPhase.work => 'Sessione focus completata!',
      TimerPhase.shortBreak => 'Pausa breve terminata',
      TimerPhase.longBreak => 'Pausa lunga terminata',
    };

    await _plugin.zonedSchedule(
      id,
      title,
      'Tocca per continuare',
      tz.TZDateTime.from(endTime, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ntako_timer_channel',
          'Timer Notifications',
          channelDescription: 'Notifiche per il timer Pomodoro',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
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

  static Future<void> cancel(int id) async {
    if (kIsWeb) return;
    await _plugin.cancel(id);
  }
}
