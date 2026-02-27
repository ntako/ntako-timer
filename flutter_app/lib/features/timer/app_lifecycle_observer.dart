import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'timer_notifier.dart';

/// Attach to WidgetsBinding to recalculate remaining timer duration
/// when the app returns from background.
class AppLifecycleObserver extends WidgetsBindingObserver {
  final WidgetRef ref;

  AppLifecycleObserver(this.ref);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(timerNotifierProvider.notifier).onAppResume();
    }
  }
}
