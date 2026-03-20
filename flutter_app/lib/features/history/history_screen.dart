import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import '../tasks/tasks_notifier.dart';

final _recentSessionsProvider = StreamProvider<List<Session>>((ref) =>
    ref.watch(appDatabaseProvider).sessionsDao.watchRecentSessions());

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(_recentSessionsProvider);
    final tasks = ref.watch(activeTasksProvider).valueOrNull ?? [];
    final tasksById = {for (final t in tasks) t.id: t};
    return Scaffold(
      appBar: AppBar(title: const Text('Storico'), centerTitle: true),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (sessions) {
          if (sessions.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, i) => _SessionTile(
              session: sessions[i],
              task: tasksById[sessions[i].taskId],
              isRunning: !sessions[i].isCompleted,
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends ConsumerStatefulWidget {
  const _EmptyState();

  @override
  ConsumerState<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends ConsumerState<_EmptyState> {
  bool _syncing = false;
  String? _error;

  Future<void> _doSync() async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await ref.read(syncServiceProvider).sync();
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 401) {
        // Token scaduto o non valido — esegui logout e mostra messaggio
        await ref.read(authNotifierProvider.notifier).logout();
        setState(() => _error = 'Sessione scaduta. Effettua nuovamente il login.');
      } else {
        setState(() => _error = 'Errore di rete: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Errore: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = ref.watch(authNotifierProvider).valueOrNull?.status ==
        AuthStatus.authenticated;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.history, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Nessuna sessione trovata.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          if (isLoggedIn) ...[
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            FilledButton.icon(
              onPressed: _syncing ? null : _doSync,
              icon: _syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync),
              label: Text(_syncing ? 'Sincronizzazione…' : 'Sincronizza ora'),
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'Accedi per importare le sessioni dal cloud.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;
  final Task? task;
  final bool isRunning;

  const _SessionTile({
    required this.session,
    this.task,
    this.isRunning = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = _typeInfo(session.type);
    final duration = _formatDuration(session.durationSeconds);
    final date = _formatDate(session.startedAt);

    return Opacity(
      opacity: isRunning ? 0.6 : 1.0,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _TypeBadge(label: label, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task?.title ?? '—',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isRunning ? '$date  •  in corso' : date,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isRunning ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ],
                ),
              ),
              isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      duration,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  (String, Color) _typeInfo(String type) => switch (type) {
    'tracking' => ('T', Colors.purple.shade600),
    _ => ('T', Colors.purple.shade600),
  };

  String _formatDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(dt.year, dt.month, dt.day);

    final time = DateFormat('HH:mm').format(dt);
    if (day == today) return 'Oggi $time';
    if (day == yesterday) return 'Ieri $time';
    return DateFormat('dd/MM HH:mm').format(dt);
  }
}

class _TypeBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _TypeBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
