import 'dart:async';
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
  /// Secure storage can fail or hang on some devices (keystore problems).
  /// Without a bound, auth would stay "loading" forever and the login button
  /// would show an endless spinner.
  static const _storageTimeout = Duration(seconds: 5);

  @override
  Future<AuthState> build() async {
    final storage = ref.read(secureStorageProvider);
    try {
      if (await storage.isLoggedIn.timeout(_storageTimeout)) {
        final email = await storage.getUserEmail().timeout(_storageTimeout);
        return AuthState(status: AuthStatus.authenticated, userEmail: email);
      }
    } catch (e) {
      // Decryption failure (e.g. corrupted keys from a previous concurrent-write
      // bug) or a hung read. Clear storage so the user can log in cleanly.
      debugPrint('[Auth] reading stored credentials failed: $e');
      await storage.clearAuth().timeout(_storageTimeout).catchError((_) {});
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
    await ref
        .read(secureStorageProvider)
        .saveAuthData(
          token: data['token'] as String,
          userId: (user['id'] as num).toInt(),
          email: user['email'] as String,
        )
        .timeout(_storageTimeout * 2);
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

  /// Message for the login/register screens. Network failures include the
  /// technical cause: it's what tells a server problem from a network one.
  String _friendlyError(Object e) {
    if (e is DioException) {
      // The body is not always our JSON: hosting error pages come back as
      // text. A cast here would throw inside the catch and leave the screen
      // loading forever.
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        return data['error'] as String;
      }
      if (e.response != null) {
        final body = data?.toString() ?? '';
        debugPrint(
          '[Auth] HTTP ${e.response!.statusCode} from ${e.requestOptions.uri}: '
          '${body.length > 500 ? body.substring(0, 500) : body}',
        );
      }
      final host = e.requestOptions.uri.host;
      final cause = e.error ?? e.message;
      final detail = cause == null ? '' : '\n($cause)';
      return switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'Il server $host non risponde (timeout).$detail',
        DioExceptionType.connectionError =>
          'Impossibile connettersi a $host.$detail',
        DioExceptionType.badCertificate =>
          'Certificato HTTPS non valido per $host.',
        DioExceptionType.badResponse =>
          'Risposta inattesa dal server (HTTP ${e.response?.statusCode}).',
        _ => 'Errore di rete verso $host.$detail',
      };
    }
    if (e is TimeoutException) {
      return 'Impossibile salvare l\'accesso sul dispositivo. '
          'Riavvia l\'app e riprova.';
    }
    debugPrint('[Auth] unexpected error: $e');
    return 'Errore: $e';
  }
}
