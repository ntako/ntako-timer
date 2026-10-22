import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../core/providers.dart';
import 'assistant_open.dart';
import 'timer_command_handler.dart';
import 'timer_commands.dart';

/// Microphone button: "avvia Arundo", "pausa", "riprendi", "ferma".
/// Uses the device's speech recognition, in Italian.
class VoiceCommandButton extends ConsumerStatefulWidget {
  const VoiceCommandButton({super.key});

  @override
  ConsumerState<VoiceCommandButton> createState() => _VoiceCommandButtonState();
}

class _VoiceCommandButtonState extends ConsumerState<VoiceCommandButton> {
  final _speech = SpeechToText();
  bool _listening = false;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    // The request may come before this screen is built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _listenIfRequested());
  }

  /// Starts listening when asked from outside (opened by the assistant).
  void _listenIfRequested() {
    if (!mounted || !ref.read(voiceListenRequestedProvider)) return;
    ref.read(voiceListenRequestedProvider.notifier).state = false;
    if (!_listening) _toggle();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _speech.stop();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final ready = await _speech.initialize(
      onStatus: (status) {
        if (mounted) {
          setState(() => _listening = status == SpeechToText.listeningStatus);
        }
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
        if (e.errorMsg != 'error_no_match' &&
            e.errorMsg != 'error_speech_timeout') {
          messenger.showSnackBar(
            SnackBar(content: Text('Microfono: ${e.errorMsg}')),
          );
        }
      },
    );
    if (!ready) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Riconoscimento vocale non disponibile o permesso negato',
          ),
        ),
      );
      return;
    }

    // Task names help the recognizer with words it wouldn't expect.
    final db = ref.read(appDatabaseProvider);
    final titles = (await db.select(db.tasks).get())
        .where((t) => t.deletedAt == null && !t.isCompleted)
        .map((t) => t.title)
        .toList();

    _handled = false;
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text(
          'Ti ascolto: "avvia <task>", "pausa", "riprendi", "ferma"',
        ),
      ),
    );
    await _speech.listen(
      onResult: (result) {
        if (!result.finalResult || _handled) return;
        _handled = true;
        final said = result.recognizedWords;
        final command = TimerCommand.fromSpeech(said);
        if (command == null) {
          messenger.showSnackBar(
            SnackBar(content: Text('Non ho capito: "$said"')),
          );
          return;
        }
        ref.read(timerCommandHandlerProvider).runAndShow(command);
      },
      listenOptions: SpeechListenOptions(
        localeId: 'it_IT',
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        partialResults: false,
        cancelOnError: true,
        contextualPhrases: titles,
      ),
    );
  }

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(voiceListenRequestedProvider, (_, requested) {
      if (requested) _listenIfRequested();
    });
    return IconButton(
      tooltip: _listening ? 'Smetti di ascoltare' : 'Comando vocale',
      icon: Icon(_listening ? Icons.mic : Icons.mic_none),
      color: _listening ? Theme.of(context).colorScheme.error : null,
      onPressed: _toggle,
    );
  }
}
