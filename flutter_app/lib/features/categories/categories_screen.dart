import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import 'categories_notifier.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catsAsync = ref.watch(activeCategoriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Categorie'), centerTitle: true),
      body: catsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (cats) {
          if (cats.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Nessuna categoria.\nCreane una con il pulsante +',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            itemCount: cats.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _CategoryCard(category: cats[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCategoryDialog(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showCategoryDialog(
    BuildContext context,
    WidgetRef ref, {
    Category? existing,
  }) {
    showDialog(
      context: context,
      builder: (_) => _CategoryDialog(ref: ref, existing: existing),
    );
  }
}

// ── Category card ─────────────────────────────────────────────────────────────

class _CategoryCard extends ConsumerWidget {
  final Category category;

  const _CategoryCard({required this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(categoriesNotifierProvider.notifier);
    final color = _parseColor(category.color);

    return Dismissible(
      key: ValueKey(category.id),
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
      confirmDismiss: (_) => _confirmDelete(context, category.name),
      onDismissed: (_) => notifier.deleteCategory(category.id),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: color,
            radius: 14,
          ),
          title: Text(
            category.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _showEdit(context, ref),
          ),
        ),
      ),
    );
  }

  void _showEdit(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => _CategoryDialog(ref: ref, existing: category),
    );
  }
}

// ── Create / Edit dialog ──────────────────────────────────────────────────────

class _CategoryDialog extends StatefulWidget {
  final WidgetRef ref;
  final Category? existing;

  const _CategoryDialog({required this.ref, this.existing});

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _nameCtrl;
  late String _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _selectedColor = widget.existing?.color ?? kCategoryColors.first;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return AlertDialog(
      title: Text(isEdit ? 'Modifica categoria' : 'Nuova categoria'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nome *',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            Text(
              'Colore',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kCategoryColors.map((hex) {
                final selected = hex == _selectedColor;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = hex),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _parseColor(hex),
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(
                              color: Theme.of(context).colorScheme.onSurface,
                              width: 3,
                            )
                          : null,
                    ),
                    child: selected
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                );
              }).toList(),
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
          onPressed: _submit,
          child: Text(isEdit ? 'Salva' : 'Crea'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final notifier =
        widget.ref.read(categoriesNotifierProvider.notifier);
    if (widget.existing != null) {
      notifier.updateCategory(
        id: widget.existing!.id,
        name: name,
        color: _selectedColor,
      );
    } else {
      notifier.createCategory(name: name, color: _selectedColor);
    }
    Navigator.pop(context);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Color _parseColor(String hex) {
  try {
    final h = hex.replaceFirst('#', '');
    return Color(int.parse('FF$h', radix: 16));
  } catch (_) {
    return const Color(0xFF6366F1);
  }
}

Future<bool> _confirmDelete(BuildContext context, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Elimina categoria'),
      content: Text(
        'Eliminare "$name"?\nI task associati perderanno la categoria.',
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
          child: const Text('Elimina'),
        ),
      ],
    ),
  );
  return result ?? false;
}
