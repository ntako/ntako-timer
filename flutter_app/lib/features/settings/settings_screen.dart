import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_notifier.dart';
import '../backup/backup_section.dart';
import '../sync/sync_service.dart';
import 'settings_notifier.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authNotifierProvider);
    final isLoggedIn =
        authAsync.valueOrNull?.status == AuthStatus.authenticated;
    final userEmail = authAsync.valueOrNull?.userEmail;
    final settingsAsync = ref.watch(settingsNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Timer'),
          settingsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
            error: (e, _) => Text('Errore impostazioni: $e'),
            data: (settings) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Durata sessione (one-shot) ─────────────────────────
                ListTile(
                  title: const Text('Durata sessione'),
                  subtitle: Text(
                    settings.sessionDurationMinutes == 0
                        ? 'Disattivato'
                        : '${settings.sessionDurationMinutes} min poi notifica pausa',
                  ),
                ),
                Slider(
                  value: settings.sessionDurationMinutes.toDouble(),
                  min: 0,
                  max: 120,
                  divisions: 24,
                  label: settings.sessionDurationMinutes == 0
                      ? 'Disattivato'
                      : '${settings.sessionDurationMinutes} min',
                  onChanged: (v) => ref
                      .read(settingsNotifierProvider.notifier)
                      .setSessionDuration(v.round()),
                ),
                const SizedBox(height: 8),

                // ── Volume allarme ────────────────────────────────────
                ListTile(
                  title: const Text('Volume allarme'),
                  subtitle: Text(
                    settings.alarmVolume == 0
                        ? 'Silenzioso'
                        : '${settings.alarmVolume}/10',
                  ),
                ),
                Slider(
                  value: settings.alarmVolume.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: settings.alarmVolume == 0
                      ? 'Silenzioso'
                      : '${settings.alarmVolume}/10',
                  onChanged: (v) => ref
                      .read(settingsNotifierProvider.notifier)
                      .setAlarmVolume(v.round()),
                ),
                const SizedBox(height: 8),

                // ── Durata pausa ──────────────────────────────────────
                ListTile(
                  title: const Text('Durata pausa'),
                  subtitle: Text(
                    settings.breakDurationMinutes == 0
                        ? 'Disattivato'
                        : '${settings.breakDurationMinutes} min',
                  ),
                ),
                Slider(
                  value: settings.breakDurationMinutes.toDouble(),
                  min: 0,
                  max: 30,
                  divisions: 30,
                  label: settings.breakDurationMinutes == 0
                      ? 'Disattivato'
                      : '${settings.breakDurationMinutes} min',
                  onChanged: (v) => ref
                      .read(settingsNotifierProvider.notifier)
                      .setBreakDuration(v.round()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _SectionHeader('Dati'),
          const BackupSection(),
          const SizedBox(height: 16),
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
