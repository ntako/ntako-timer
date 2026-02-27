import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import 'settings_notifier.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsNotifierProvider);
    final authAsync = ref.watch(authNotifierProvider);
    final isLoggedIn =
        authAsync.valueOrNull?.status == AuthStatus.authenticated;
    final userEmail = authAsync.valueOrNull?.userEmail;

    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni'), centerTitle: true),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (settings) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeader('Timer'),
            _DurationTile(
              label: 'Focus',
              value: settings.workMinutes,
              min: 1,
              max: 90,
              onChanged: (v) => ref.read(settingsNotifierProvider.notifier)
                  .saveSettings(settings.copyWith(workMinutes: v)),
            ),
            _DurationTile(
              label: 'Pausa breve',
              value: settings.shortBreakMinutes,
              min: 1,
              max: 30,
              onChanged: (v) => ref.read(settingsNotifierProvider.notifier)
                  .saveSettings(settings.copyWith(shortBreakMinutes: v)),
            ),
            _DurationTile(
              label: 'Pausa lunga',
              value: settings.longBreakMinutes,
              min: 1,
              max: 60,
              onChanged: (v) => ref.read(settingsNotifierProvider.notifier)
                  .saveSettings(settings.copyWith(longBreakMinutes: v)),
            ),
            _DurationTile(
              label: 'Pomodori prima della pausa lunga',
              value: settings.pomodorosBeforeLongBreak,
              min: 2,
              max: 8,
              onChanged: (v) => ref.read(settingsNotifierProvider.notifier)
                  .saveSettings(settings.copyWith(pomodorosBeforeLongBreak: v)),
            ),
            const Divider(height: 32),
            const _SectionHeader('Account & Sync'),
            if (isLoggedIn) ...[
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(userEmail ?? ''),
                subtitle: const Text('Account attivo'),
              ),
              ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Sincronizza ora'),
                onTap: () async {
                  try {
                    await ref.read(syncServiceProvider).sync();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sincronizzazione completata')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Errore sync: $e')),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text(
                  'Esci',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  await ref.read(authNotifierProvider.notifier).logout();
                },
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Accedi'),
                subtitle: const Text('Accedi per sincronizzare i dati'),
                onTap: () => context.go('/login'),
              ),
              ListTile(
                leading: const Icon(Icons.person_add),
                title: const Text('Crea account'),
                onTap: () => context.go('/register'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _DurationTile extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _DurationTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max - min,
        label: '$value min',
        onChanged: (v) => onChanged(v.round()),
      ),
      trailing: SizedBox(
        width: 48,
        child: Text(
          '$value min',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.right,
        ),
      ),
    );
  }
}
