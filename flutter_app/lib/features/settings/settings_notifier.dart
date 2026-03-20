import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/providers.dart';

part 'settings_notifier.g.dart';

@immutable
class AppSettings {
  final int alarmVolume;            // 0 = silent; 1-10 = with sound
  final int breakDurationMinutes;   // 0 = disabled
  final int sessionDurationMinutes; // 0 = disabled; one-shot at N min

  const AppSettings({
    this.alarmVolume = 8,
    this.breakDurationMinutes = 15,
    this.sessionDurationMinutes = 120,
  });

  AppSettings copyWith({
    int? alarmVolume,
    int? breakDurationMinutes,
    int? sessionDurationMinutes,
  }) =>
      AppSettings(
        alarmVolume:            alarmVolume            ?? this.alarmVolume,
        breakDurationMinutes:   breakDurationMinutes   ?? this.breakDurationMinutes,
        sessionDurationMinutes: sessionDurationMinutes ?? this.sessionDurationMinutes,
      );
}

@Riverpod(keepAlive: true)
class SettingsNotifier extends _$SettingsNotifier {
  @override
  Future<AppSettings> build() async {
    final db = ref.read(appDatabaseProvider);
    final volumeStr  = await db.settingsDao.getValue('alarm_volume');
    final breakStr   = await db.settingsDao.getValue('break_duration_min');
    final sessionStr = await db.settingsDao.getValue('session_duration_min');
    return AppSettings(
      alarmVolume:            int.tryParse(volumeStr  ?? '') ?? 8,
      breakDurationMinutes:   int.tryParse(breakStr   ?? '') ?? 15,
      sessionDurationMinutes: int.tryParse(sessionStr ?? '') ?? 120,
    );
  }

  Future<void> setAlarmVolume(int volume) async {
    await ref.read(appDatabaseProvider).settingsDao.setValue('alarm_volume', volume.toString());
    final current = state.valueOrNull ?? const AppSettings();
    state = AsyncData(current.copyWith(alarmVolume: volume));
  }

  Future<void> setBreakDuration(int minutes) async {
    await ref.read(appDatabaseProvider).settingsDao.setValue('break_duration_min', minutes.toString());
    final current = state.valueOrNull ?? const AppSettings();
    state = AsyncData(current.copyWith(breakDurationMinutes: minutes));
  }

  Future<void> setSessionDuration(int minutes) async {
    await ref.read(appDatabaseProvider).settingsDao.setValue('session_duration_min', minutes.toString());
    final current = state.valueOrNull ?? const AppSettings();
    state = AsyncData(current.copyWith(sessionDurationMinutes: minutes));
  }
}
