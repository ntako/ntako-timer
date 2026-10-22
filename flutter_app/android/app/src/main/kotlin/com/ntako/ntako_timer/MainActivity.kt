package com.ntako.ntako_timer

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Tells Dart when Google Assistant / Gemini opened the app ("Ok Google,
 * apri Workadoro"), so it can start listening for a command right away.
 * Opening from the launcher icon doesn't count.
 */
class MainActivity : FlutterActivity() {
    private var openedByAssistant = false
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // A restored activity replays its old intent: not a new opening.
        openedByAssistant = savedInstanceState == null && isAssistantOpen(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeAssistantOpen") {
                    result.success(openedByAssistant)
                    openedByAssistant = false
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isAssistantOpen(intent)) channel?.invokeMethod("assistantOpen", null)
    }

    // The launcher intent (no command link), started by the Google app.
    private fun isAssistantOpen(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_MAIN && intent.data == null &&
            referrer?.host in ASSISTANTS

    companion object {
        private const val CHANNEL = "com.ntako.ntako_timer/launch"
        private val ASSISTANTS = setOf(
            "com.google.android.googlequicksearchbox",
            "com.google.android.apps.bard",
        )
    }
}
