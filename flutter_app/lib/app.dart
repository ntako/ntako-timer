import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/categories/categories_screen.dart';
import 'features/history/history_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/tasks/tasks_screen.dart';
import 'features/timer/app_lifecycle_observer.dart';
import 'features/timer/timer_notifier.dart';
import 'features/timer/timer_screen.dart';

class NtakoTimerApp extends ConsumerWidget {
  const NtakoTimerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'NTAKO Timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE84545),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE84545),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }

  static final _router = GoRouter(
    initialLocation: '/timer',
    routes: [
      ShellRoute(
        builder: (context, state, child) => _MainShell(child: child),
        routes: [
          GoRoute(
            path: '/timer',
            builder: (ctx, st) => const TimerScreen(),
          ),
          GoRoute(
            path: '/tasks',
            builder: (ctx, st) => const TasksScreen(),
          ),
          GoRoute(
            path: '/history',
            builder: (ctx, st) => const HistoryScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (ctx, st) => const SettingsScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/categories',
        builder: (ctx, st) => const CategoriesScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (ctx, st) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (ctx, st) => const RegisterScreen(),
      ),
    ],
  );
}

class _MainShell extends ConsumerStatefulWidget {
  final Widget child;

  const _MainShell({required this.child});

  @override
  ConsumerState<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<_MainShell>
    with WidgetsBindingObserver {
  late final AppLifecycleObserver _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = AppLifecycleObserver(ref);
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(timerNotifierProvider.notifier).recoverDanglingSession();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;

    int selectedIndex = switch (location) {
      '/timer' => 0,
      '/tasks' => 1,
      '/history' => 2,
      '/settings' => 3,
      _ => 0,
    };

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (i) {
          switch (i) {
            case 0:
              context.go('/timer');
            case 1:
              context.go('/tasks');
            case 2:
              context.go('/history');
            case 3:
              context.go('/settings');
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.timer_outlined),
            selectedIcon: Icon(Icons.timer),
            label: 'Timer',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: 'Task',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'Storico',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Impostazioni',
          ),
        ],
      ),
    );
  }
}
