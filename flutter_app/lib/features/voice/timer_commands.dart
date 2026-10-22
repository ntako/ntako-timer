import '../../core/database/app_database.dart';

/// Commands that drive the timer from outside its screen: launcher
/// shortcuts, Siri, Google Assistant (App Actions) and the in-app
/// microphone all end up here.
///
/// Links: `ntako://timer/start[?task=<name>]`, `ntako://timer/pause`,
/// `ntako://timer/resume`, `ntako://timer/stop`.

enum TimerCommandAction { start, pause, resume, stop }

class TimerCommand {
  final TimerCommandAction action;

  /// Task name as spoken or typed (start only); null = the selected task.
  final String? task;

  const TimerCommand(this.action, {this.task});

  static const scheme = 'ntako';

  /// `ntako://timer/<action>[?task=…]`; null for anything else.
  static TimerCommand? fromUri(Uri uri) {
    if (uri.scheme != scheme || uri.host != 'timer') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 1) return null;
    final action = switch (segments.single) {
      'start' => TimerCommandAction.start,
      'pause' => TimerCommandAction.pause,
      'resume' => TimerCommandAction.resume,
      'stop' => TimerCommandAction.stop,
      _ => null,
    };
    if (action == null) return null;
    final task = uri.queryParameters['task']?.trim();
    return TimerCommand(
      action,
      task: task == null || task.isEmpty ? null : task,
    );
  }

  // Spoken Italian (and a little English), longest phrases first so that
  // "metti in pausa" isn't read as "pausa" + task name.
  static const _verbs = <(String, TimerCommandAction)>[
    ('metti in pausa', TimerCommandAction.pause),
    ('fai una pausa', TimerCommandAction.pause),
    ('ricomincia', TimerCommandAction.resume),
    ('riprendi', TimerCommandAction.resume),
    ('continua', TimerCommandAction.resume),
    ('resume', TimerCommandAction.resume),
    ('pausa', TimerCommandAction.pause),
    ('pause', TimerCommandAction.pause),
    ('termina', TimerCommandAction.stop),
    ('ferma', TimerCommandAction.stop),
    ('basta', TimerCommandAction.stop),
    ('stop', TimerCommandAction.stop),
    ('avvia', TimerCommandAction.start),
    ('inizia', TimerCommandAction.start),
    ('comincia', TimerCommandAction.start),
    ('parti', TimerCommandAction.start),
    ('start', TimerCommandAction.start),
  ];

  // Filler between the verb and the task name: "avvia il timer su Arundo".
  static final _filler = RegExp(
    r'^(?:(?:il |la |lo |un |una )?(?:timer|tracking|sessione|lavoro|task|progetto)\s*)?'
    r'(?:(?:su|per|di|con|sul|sulla|sullo|del|della|dello|al|alla|on|for)\s+)?'
    r'(?:(?:il|la|lo|l|i|gli|le|task|progetto)\s+)?',
  );

  /// "avvia il timer su Arundo" → start(task: "Arundo"); null if no
  /// command verb is recognised.
  static TimerCommand? fromSpeech(String text) {
    final said = normalize(text);
    for (final (verb, action) in _verbs) {
      final at = RegExp(
        '(?:^| )${RegExp.escape(verb)}(?: |\$)',
      ).firstMatch(said);
      if (at == null) continue;
      if (action != TimerCommandAction.start) return TimerCommand(action);
      final rest = said
          .substring(at.end)
          .trim()
          .replaceFirst(_filler, '')
          .trim();
      return TimerCommand(action, task: rest.isEmpty ? null : rest);
    }
    return null;
  }
}

/// Lowercase, no accents, no punctuation, single spaces: what voice
/// recognition and typed names have in common.
String normalize(String s) {
  const accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
  };
  final lower = s.toLowerCase().split('').map((c) => accents[c] ?? c).join();
  return lower
      .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}

class TaskMatch {
  final Task? task;

  /// Several tasks fit equally well: the caller should ask, not guess.
  final List<Task> ambiguous;

  const TaskMatch(this.task, [this.ambiguous = const []]);
}

/// "Sviluppo (Arundo)": tasks can share a title across categories.
String taskLabel(Task task, Map<String, String> categoryNames) {
  final category = categoryNames[task.categoryId];
  return category == null ? task.title : '${task.title} ($category)';
}

// Small words between a task and its category: "sviluppo di arundo".
const _linkWords = {
  'di', 'del', 'della', 'dello', 'per', 'in', 'nel', 'nella', 'su', 'sul',
  'sulla', 'of', 'for', 'on',
};

/// Finds an open task (not completed, not deleted) by spoken name, from
/// strictest to loosest: same title, same title plus category name, title
/// starting with the words, title with a word starting with them, every
/// word found in title or category. Partial matches only count from the
/// start of a word ("svil" finds "Sviluppo", "test" doesn't find
/// "Contest"). Ties at the first level that matches are reported as
/// ambiguous. [categoryNames]: category id → name.
TaskMatch matchTask(
  List<Task> tasks,
  String spoken, {
  Map<String, String> categoryNames = const {},
}) {
  final query = normalize(spoken);
  if (query.isEmpty) return const TaskMatch(null);
  final open = [
    for (final t in tasks)
      if (t.deletedAt == null && !t.isCompleted && normalize(t.title).isNotEmpty)
        (
          t,
          normalize(t.title),
          normalize('${t.title} ${categoryNames[t.categoryId] ?? ''}'),
        ),
  ];
  final words = query.split(' ').where((w) => !_linkWords.contains(w)).toList();
  final levels = <bool Function(String name, String full)>[
    (name, full) => name == query,
    (name, full) => full == words.join(' '),
    (name, full) => name.startsWith(query),
    (name, full) => ' $name'.contains(' $query'),
    (name, full) =>
        words.isNotEmpty &&
        words.every((w) => full.split(' ').any((n) => n.startsWith(w))),
  ];
  for (final fits in levels) {
    final hits = [
      for (final (task, name, full) in open)
        if (fits(name, full)) task,
    ];
    if (hits.length == 1) return TaskMatch(hits.single);
    if (hits.length > 1) return TaskMatch(null, hits);
  }
  return const TaskMatch(null);
}
