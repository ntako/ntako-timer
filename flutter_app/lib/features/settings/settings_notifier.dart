import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/providers.dart';

part 'settings_notifier.g.dart';

@immutable
class AppSettings {
  final int workMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;
  final int pomodorosBeforeLongBreak;

  const AppSettings({
    this.workMinutes = 25,
    this.shortBreakMinutes = 5,
    this.longBreakMinutes = 15,
    this.pomodorosBeforeLongBreak = 4,
  });

  AppSettings copyWith({
    int? workMinutes,
    int? shortBreakMinutes,
    int? longBreakMinutes,
    int? pomodorosBeforeLongBreak,
  }) => AppSettings(
    workMinutes: workMinutes ?? this.workMinutes,
    shortBreakMinutes: shortBreakMinutes ?? this.shortBreakMinutes,
    longBreakMinutes: longBreakMinutes ?? this.longBreakMinutes,
    pomodorosBeforeLongBreak:
        pomodorosBeforeLongBreak ?? this.pomodorosBeforeLongBreak,
  );
}

@Riverpod(keepAlive: true)
class SettingsNotifier extends _$SettingsNotifier {
  @override
  Future<AppSettings> build() async {
    final dao = ref.read(appDatabaseProvider).settingsDao;

    Future<int> get(String key, int defaultValue) async {
      final v = await dao.getValue(key);
      return v != null ? (int.tryParse(v) ?? defaultValue) : defaultValue;
    }

    return AppSettings(
      workMinutes: await get('work_minutes', 25),
      shortBreakMinutes: await get('short_break_minutes', 5),
      longBreakMinutes: await get('long_break_minutes', 15),
      pomodorosBeforeLongBreak: await get('pomodoros_before_long_break', 4),
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    final dao = ref.read(appDatabaseProvider).settingsDao;
    await Future.wait([
      dao.setValue('work_minutes', settings.workMinutes.toString()),
      dao.setValue(
        'short_break_minutes',
        settings.shortBreakMinutes.toString(),
      ),
      dao.setValue('long_break_minutes', settings.longBreakMinutes.toString()),
      dao.setValue(
        'pomodoros_before_long_break',
        settings.pomodorosBeforeLongBreak.toString(),
      ),
    ]);
    state = AsyncValue.data(settings);
  }
}
