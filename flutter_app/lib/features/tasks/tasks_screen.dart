import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/database/app_database.dart';
import '../auth/auth_notifier.dart';
import '../categories/categories_notifier.dart';
import '../sync/sync_service.dart';
import '../voice/timer_commands.dart';
import 'tasks_notifier.dart';

// ── Duration format helper ────────────────────────────────────────────────────

String _fmtDuration(int totalSec) {
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '< 1m';
}

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
          if (ref.watch(authNotifierProvider).valueOrNull?.status ==
              AuthStatus.authenticated)
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sincronizza',
              onPressed: () async {
                try {
                  await ref.read(syncServiceProvider).sync();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sincronizzazione completata'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (_) {}
              },
            ),
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
        onPressed: () => showDialog(
          context: context,
          builder: (_) => _TaskDialog(ref: ref),
        ),
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
    final totals = ref.watch(taskTotalsProvider).valueOrNull ?? {};
    final totalSec = totals[task.id] ?? 0;

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
          child: Row(
            children: [
              Tooltip(
                message: 'Segna come completato',
                child: Checkbox(
                  value: false,
                  onChanged: (_) => notifier.toggleComplete(task),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (task.description != null && task.description!.isNotEmpty)
                      Text(
                        task.description!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (category != null || totalSec > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            if (category != null) ...[
                              CircleAvatar(
                                backgroundColor: _parseColor(category!.color),
                                radius: 4,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                category!.name,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: _parseColor(category!.color)),
                              ),
                              if (totalSec > 0) const SizedBox(width: 8),
                            ],
                            if (totalSec > 0)
                              Row(
                                children: [
                                  Icon(
                                    Icons.timer_outlined,
                                    size: 12,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    _fmtDuration(totalSec),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(context).colorScheme.outline,
                                        ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
                tooltip: 'Modifica task',
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => _TaskDialog(ref: ref, task: task),
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
    final totals = ref.watch(taskTotalsProvider).valueOrNull ?? {};
    final totalSec = totals[task.id] ?? 0;

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
                      totalSec > 0
                          ? 'Tempo totale: ${_fmtDuration(totalSec)}'
                          : 'Tracking completato',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
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

// ── Create / Edit task dialog ─────────────────────────────────────────────────
// Pass [task] to edit an existing task; omit to create a new one.

class _TaskDialog extends StatefulWidget {
  final WidgetRef ref;
  final Task? task;

  const _TaskDialog({required this.ref, this.task});

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  String? _selectedCategoryId;

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.task?.title ?? '');
    _descCtrl  = TextEditingController(text: widget.task?.description ?? '');
    _selectedCategoryId = widget.task?.categoryId;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  /// Two tasks with the same name in the same category can't be told apart
  /// (by voice, in the timer's list): ask before creating one.
  Future<bool> _confirmIfDuplicate(String title) async {
    final name = normalize(title);
    final tasks = widget.ref.read(activeTasksProvider).value ?? [];
    final twin = tasks.any(
      (t) =>
          t.id != widget.task?.id &&
          t.categoryId == _selectedCategoryId &&
          normalize(t.title) == name,
    );
    if (!twin) return true;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Task già esistente'),
            content: Text(
              'In questa categoria c\'è già un task «$title». '
              'Con due task uguali i comandi vocali non sapranno quale scegliere.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annulla'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(_isEdit ? 'Salva comunque' : 'Crea comunque'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.ref.watch(activeCategoriesProvider).value ?? [];

    return AlertDialog(
      title: Text(_isEdit ? 'Modifica task' : 'Nuovo task'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Titolo ────────────────────────────────────────────────────
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Titolo *',
                border: OutlineInputBorder(),
              ),
              autofocus: !_isEdit,
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
              // Grows for long notes (e.g. imported commit logs), then scrolls.
              minLines: 2,
              maxLines: 8,
            ),
            const SizedBox(height: 16),

            // ── Categoria ─────────────────────────────────────────────────
            DropdownButtonFormField<String?>(
              value: cats.any((c) => c.id == _selectedCategoryId)
                  ? _selectedCategoryId
                  : null,
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () async {
            final title = _titleCtrl.text.trim();
            if (title.isEmpty) return;
            final desc = _descCtrl.text.trim().isNotEmpty
                ? _descCtrl.text.trim()
                : null;
            if (!await _confirmIfDuplicate(title)) return;
            if (!context.mounted) return;
            if (_isEdit) {
              widget.ref.read(tasksNotifierProvider.notifier).saveTaskEdit(
                id: widget.task!.id,
                title: title,
                description: desc,
                categoryId: _selectedCategoryId,
              );
            } else {
              widget.ref.read(tasksNotifierProvider.notifier).createTask(
                title: title,
                description: desc,
                categoryId: _selectedCategoryId,
              );
            }
            Navigator.pop(context);
          },
          child: Text(_isEdit ? 'Salva' : 'Crea'),
        ),
      ],
    );
  }
}
