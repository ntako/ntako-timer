import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

// MARK: - Siri and Shortcuts
//
// Each intent opens the app and an ntako://timer/… link in it; the Dart side
// (app_links → TimerCommandHandler) runs the command, exactly as for the
// Android launcher shortcuts and Google Assistant. The phrases are Italian:
// the project's development region is "it".

/// Opens ntako://timer/<action>[?task=…] in this app.
@MainActor
private func openTimerLink(_ action: String, task: String? = nil) async {
  var components = URLComponents()
  components.scheme = "ntako"
  components.host = "timer"
  components.path = "/\(action)"
  if let task, !task.trimmingCharacters(in: .whitespaces).isEmpty {
    components.queryItems = [URLQueryItem(name: "task", value: task)]
  }
  guard let url = components.url else { return }
  _ = await UIApplication.shared.open(url)
}

/// "Avvia Ntako Timer": starts on the task selected in the app.
struct StartTimerIntent: AppIntent {
  static var title: LocalizedStringResource = "Avvia il timer"
  static var description = IntentDescription("Avvia il timer sul task selezionato nell'app.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await openTimerLink("start")
    return .result()
  }
}

/// "Avvia un task su Ntako Timer": Siri asks which task.
struct StartTaskIntent: AppIntent {
  static var title: LocalizedStringResource = "Avvia il timer su un task"
  static var description = IntentDescription("Avvia il timer sul task indicato per nome.")
  static var openAppWhenRun = true

  @Parameter(title: "Task", requestValueDialog: "Su quale task?")
  var task: String

  @MainActor
  func perform() async throws -> some IntentResult {
    await openTimerLink("start", task: task)
    return .result()
  }
}

struct PauseTimerIntent: AppIntent {
  static var title: LocalizedStringResource = "Metti in pausa il timer"
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await openTimerLink("pause")
    return .result()
  }
}

struct ResumeTimerIntent: AppIntent {
  static var title: LocalizedStringResource = "Riprendi il timer"
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await openTimerLink("resume")
    return .result()
  }
}

struct StopTimerIntent: AppIntent {
  static var title: LocalizedStringResource = "Ferma il timer"
  static var description = IntentDescription("Ferma il timer e salva la sessione.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await openTimerLink("stop")
    return .result()
  }
}

/// Phrases available to Siri as soon as the app is installed, no setup.
/// Every phrase must contain the app name.
struct NtakoTimerShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartTimerIntent(),
      phrases: [
        "Avvia \(.applicationName)",
        "Avvia il timer di \(.applicationName)",
        "Inizia a lavorare con \(.applicationName)",
      ]
    )
    AppShortcut(
      intent: StartTaskIntent(),
      phrases: [
        "Avvia un task su \(.applicationName)",
        "Avvia \(.applicationName) su un task",
      ]
    )
    AppShortcut(
      intent: PauseTimerIntent(),
      phrases: [
        "Metti in pausa \(.applicationName)",
        "Pausa \(.applicationName)",
      ]
    )
    AppShortcut(
      intent: ResumeTimerIntent(),
      phrases: [
        "Riprendi \(.applicationName)",
        "Continua \(.applicationName)",
      ]
    )
    AppShortcut(
      intent: StopTimerIntent(),
      phrases: [
        "Ferma \(.applicationName)",
        "Ferma il timer di \(.applicationName)",
      ]
    )
  }
}
