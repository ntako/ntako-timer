import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'remote_sessions.dart';
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
      // Catch up with timers started or stopped elsewhere meanwhile.
      syncIfLoggedIn(ref.read);
    }
  }
}
