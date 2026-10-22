import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set when the timer screen's microphone should start listening on its
/// own; the button clears it once it does.
final voiceListenRequestedProvider = StateProvider<bool>((ref) => false);

/// "Ok Google, apri Workadoro": Android tells (see MainActivity.kt) when
/// Google Assistant or Gemini opened the app, so that the user can say the
/// command right after, without touching the phone.
class AssistantOpen {
  static const _channel = MethodChannel('com.ntako.ntako_timer/launch');

  /// Calls [onOpen] if the assistant opened the app, and again every time
  /// it brings the app back to the front. Android only.
  static Future<void> listen(void Function() onOpen) async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'assistantOpen') onOpen();
    });
    if (await _channel.invokeMethod<bool>('takeAssistantOpen') ?? false) {
      onOpen();
    }
  }
}
