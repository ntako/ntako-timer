import 'package:flutter/material.dart';

/// Shows snackbars from anywhere: links, voice commands and sync events
/// arrive outside any screen's context.
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showRootMessage(String message, {SnackBarAction? action}) {
  rootMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        duration: Duration(seconds: action == null ? 4 : 8),
      ),
    );
}
