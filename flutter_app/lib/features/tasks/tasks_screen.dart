import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/database/app_database.dart';
import '../categories/categories_notifier.dart';
import 'tasks_notifier.dart';

// ── Color helper ──────────────────────────────────────────────────────────────

Color _parseColor(String hex) {
  try {
    final h = hex.replaceFirst('#', '');
    return Color(int.parse('FF$h', radix: 16));
  } catch (_) {
    return const Color(0xFF6366F1);
  }
}

// ── Main screen ───────────────────────────────────────────────────────────────

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(activeTasksProvider);
    final catsAsync = ref.watch(activeCategoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Task'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: 'Gestisci categorie',
            onPressed: () => context.push('/categories'),
          ),
        ],
      ),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (allTasks) {
          final cats = catsAsync.value ?? [];

          if (allTasks.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.checklist, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Nessun task ancora.\nCreane uno con il pulsante +',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          final active = allTasks.where((t) => !t.isCompleted).toList();
          final completed = allTasks.where((t) => t.isCompleted).toList();
          final catMap = {for (final c in cats) c.id: c};

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            children: [
              // ── Active tasks grouped by category ──────────────────────────
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Nessun task attivo',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                ..._buildGrouped(context, ref, active, catMap),

              // ── Completed section ─────────────────────────────────────────
              if (completed.isNotEmpty) ...[
                const SizedBox(height: 8),
                _SectionHeader(
                  label: 'Completati (${completed.length})',
                  onClear: () => _confirmClearCompleted(context, ref),
                ),
                const SizedBox(height: 8),
                ...completed.map(
                  (t) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CompletedTaskCard(
                      task: t,
                      category: t.categoryId != null ? catMap[t.categoryId] : null,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateDialog(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  List<Widget> _buildGrouped(
    BuildContext context,
    WidgetRef ref,
    List<Task> tasks,
    Map<String, Category> catMap,
  ) {
    final Map<String?, List<Task>> grouped = {};
    for (final t in tasks) {
      grouped.putIfAbsent(t.categoryId, () => []).add(t);
    }

    final widgets = <Widget>[];

    // Categorized tasks, sorted alphabetically by category name
    final catKeys = grouped.keys.where((k) => k != null).toList()
      ..sort((a, b) => (catMap[a]?.name ?? '').compareTo(catMap[b]?.name ?? ''));

    for (final catId in catKeys) {
      final cat = catMap[catId];
      if (cat == null) continue;
      widgets.add(_CategoryGroupHeader(category: cat));
      widgets.add(const SizedBox(height: 4));
      for (final t in grouped[catId]!) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TaskCard(task: t, category: cat),
          ),
        );
      }
      widgets.add(const SizedBox(height: 8));
    }

    // Uncategorized at the bottom
    if (grouped[null] != null && grouped[null]!.isNotEmpty) {
      if (catKeys.isNotEmpty) {
        widgets.add(_SectionHeader(label: 'Senza categoria'));
        widgets.add(const SizedBox(height: 4));
      }
      for (final t in grouped[null]!) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TaskCard(task: t),
          ),
        );
      }
    }

    return widgets;
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => _CreateTaskDialog(ref: ref),
    );
  }
}

// ── Category group header ─────────────────────────────────────────────────────

class _CategoryGroupHeader extends StatelessWidget {
  final Category category;

  const _CategoryGroupHeader({required this.category});

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(category.color);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          CircleAvatar(backgroundColor: color, radius: 6),
          const SizedBox(width: 8),
          Text(
            category.name,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: color.withOpacity(0.4))),
        ],
      ),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final VoidCallback? onClear;

  const _SectionHeader({required this.label, this.onClear});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        if (onClear != null) ...[
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('Cancella tutto'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Active task card ──────────────────────────────────────────────────────────

class _TaskCard extends ConsumerWidget {
  final Task task;
  final Category? category;

  const _TaskCard({required this.task, this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(tasksNotifierProvider.notifier);
    final isPomodoro = task.type == 'pomodoro';
    final progress = isPomodoro && task.pomodoroGoal > 0
        ? task.pomodorosDone / task.pomodoroGoal
        : 0.0;

    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(context, task.title),
      onDismissed: (_) => notifier.deleteTask(task.id),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Tooltip(
                    message: 'Segna come completato',
                    child: Checkbox(
                      value: false,
                      onChanged: (_) => notifier.toggleComplete(task),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      task.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _TypeBadge(isPomodoro: isPomodoro),
                ],
              ),
              if (task.description != null && task.description!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 8),
                  child: Text(
                    task.description!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (isPomodoro)
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${task.pomodorosDone}/${task.pomodoroGoal} 🍅',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Completed task card ───────────────────────────────────────────────────────

class _CompletedTaskCard extends ConsumerWidget {
  final Task task;
  final Category? category;

  const _CompletedTaskCard({required this.task, this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(tasksNotifierProvider.notifier);
    final isPomodoro = task.type == 'pomodoro';

    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(context, task.title),
      onDismissed: (_) => notifier.deleteTask(task.id),
      child: Card(
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough,
                        decorationColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      isPomodoro
                          ? '${task.pomodorosDone} pomodori completati'
                          : 'Tracking completato',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => notifier.toggleComplete(task),
                child: const Text('Ripristina'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Type badge ────────────────────────────────────────────────────────────────

class _TypeBadge extends StatelessWidget {
  final bool isPomodoro;

  const _TypeBadge({required this.isPomodoro});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isPomodoro
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isPomodoro ? '🍅 Pomodoro' : '⏱ Tracker',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isPomodoro
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

// ── Delete confirmation ───────────────────────────────────────────────────────

Future<bool> _confirmDelete(BuildContext context, String title) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Elimina task'),
      content: Text('Eliminare "$title"?\nL\'operazione non è reversibile.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Elimina'),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<void> _confirmClearCompleted(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Cancella storico'),
      content: const Text(
        'Eliminare tutti i task completati?\nL\'operazione non è reversibile.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Elimina tutti'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(tasksNotifierProvider.notifier).deleteAllCompleted();
  }
}

// ── Create task dialog ────────────────────────────────────────────────────────

class _CreateTaskDialog extends StatefulWidget {
  final WidgetRef ref;

  const _CreateTaskDialog({required this.ref});

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  int _pomodoroGoal = 4;
  String _type = 'pomodoro';
  String? _selectedCategoryId;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.ref.watch(activeCategoriesProvider).value ?? [];

    return AlertDialog(
      title: const Text('Nuovo task'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Tipo ──────────────────────────────────────────────────────
            Text('Tipo', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'pomodoro',
                  label: Text('🍅 Pomodoro'),
                ),
                ButtonSegment(
                  value: 'tracker',
                  label: Text('⏱ Tracker'),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),

            // ── Titolo ────────────────────────────────────────────────────
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Titolo *',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),

            // ── Descrizione ───────────────────────────────────────────────
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Descrizione',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            // ── Categoria ─────────────────────────────────────────────────
            if (cats.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                value: _selectedCategoryId,
                decoration: const InputDecoration(
                  labelText: 'Categoria',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Nessuna categoria'),
                  ),
                  ...cats.map(
                    (c) => DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: _parseColor(c.color),
                            radius: 8,
                          ),
                          const SizedBox(width: 8),
                          Text(c.name),
                        ],
                      ),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              ),
              const SizedBox(height: 16),
            ],

            // ── Obiettivo Pomodori (solo pomodoro) ────────────────────────
            if (_type == 'pomodoro')
              Row(
                children: [
                  const Text('Obiettivo Pomodori:'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: _pomodoroGoal > 1
                        ? () => setState(() => _pomodoroGoal--)
                        : null,
                  ),
                  Text(
                    '$_pomodoroGoal',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _pomodoroGoal < 20
                        ? () => setState(() => _pomodoroGoal++)
                        : null,
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () {
            final title = _titleCtrl.text.trim();
            if (title.isEmpty) return;
            widget.ref.read(tasksNotifierProvider.notifier).createTask(
              title: title,
              type: _type,
              description: _descCtrl.text.trim().isNotEmpty
                  ? _descCtrl.text.trim()
                  : null,
              categoryId: _selectedCategoryId,
              pomodoroGoal: _pomodoroGoal,
            );
            Navigator.pop(context);
          },
          child: const Text('Crea'),
        ),
      ],
    );
  }
}
