import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../core/providers.dart';
import '../sync/sync_service.dart';

part 'auth_notifier.g.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

@immutable
class AuthState {
  final AuthStatus status;
  final String? userEmail;
  final String? error;

  const AuthState({required this.status, this.userEmail, this.error});
}

@Riverpod(keepAlive: true)
class AuthNotifier extends _$AuthNotifier {
  @override
  Future<AuthState> build() async {
    final storage = ref.read(secureStorageProvider);
    try {
      if (await storage.isLoggedIn) {
        final email = await storage.getUserEmail();
        return AuthState(status: AuthStatus.authenticated, userEmail: email);
      }
    } catch (_) {
      // Decryption failure (e.g. corrupted keys from a previous concurrent-write
      // bug). Clear storage so the user can log in cleanly.
      await storage.clearAuth();
    }
    return const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<void> register(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final data = await ref.read(apiClientProvider).post('/auth/register', {
        'email': email,
        'password': password,
      });
      await _persist(data);
    } catch (e, st) {
      state = AsyncValue.error(_friendlyError(e), st);
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final data = await ref.read(apiClientProvider).post('/auth/login', {
        'email': email,
        'password': password,
      });
      await _persist(data);
    } catch (e, st) {
      state = AsyncValue.error(_friendlyError(e), st);
    }
  }

  Future<void> logout() async {
    await ref.read(secureStorageProvider).clearAuth();
    state = const AsyncValue.data(
      AuthState(status: AuthStatus.unauthenticated),
    );
  }

  Future<void> _persist(Map<String, dynamic> data) async {
    final user = data['user'] as Map<String, dynamic>;
    await ref.read(secureStorageProvider).saveAuthData(
      token: data['token'] as String,
      userId: (user['id'] as num).toInt(),
      email: user['email'] as String,
    );
    state = AsyncValue.data(
      AuthState(
        status: AuthStatus.authenticated,
        userEmail: user['email'] as String,
      ),
    );
    // The stored pull cursor may belong to another account: start over.
    final sync = ref.read(syncServiceProvider);
    await sync.resetCursor();
    // Pull data from the server in the background; ignore errors silently
    // (the user can manually sync from Settings if this fails).
    sync.sync().ignore();
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      final msg = (e.response?.data as Map?)?['error'];
      if (msg is String) return msg;
      return switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout => 'Timeout di connessione',
        DioExceptionType.connectionError => 'Impossibile connettersi al server',
        _ => 'Errore di rete',
      };
    }
    return 'Errore sconosciuto';
  }
}
