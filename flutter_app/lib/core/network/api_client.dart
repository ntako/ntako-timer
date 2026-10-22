import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../storage/secure_storage.dart';

class ApiClient {
  // Inject at build time: --dart-define=API_BASE_URL=https://yourserver.com/api
  // Default for local dev with Flutter web
  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080/api',
  );

  /// Settings key of the server address chosen in the app, if any.
  static const baseUrlSettingsKey = 'api_base_url';

  final Dio _dio;
  final SecureStorageService _secureStorage;

  String _baseUrl = defaultBaseUrl;

  /// Resolves once the stored address (if any) is applied. Every request
  /// waits for it, so none goes to the default server by mistake.
  late final Future<void> _baseUrlLoaded;

  /// [storedBaseUrl] is the address saved in the app settings, if any.
  ApiClient(this._secureStorage, {Future<String?>? storedBaseUrl})
    : _dio = Dio(
        BaseOptions(
          baseUrl: defaultBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          // Without it, a connection that stalls while sending the body
          // (seen on some networks) leaves the request pending forever.
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'Content-Type': 'application/json'},
        ),
      ) {
    _baseUrlLoaded = (storedBaseUrl ?? Future.value(null))
        .timeout(const Duration(seconds: 5))
        .then((url) {
          if (url != null && url.isNotEmpty) _baseUrl = url;
        })
        .catchError((Object e) {
          debugPrint('[ApiClient] loading the server address failed: $e');
        });
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _prepare, onError: _handleError),
    );
  }

  /// The server address requests go to.
  String get baseUrl => _baseUrl;

  /// [baseUrl] once the stored address has been loaded: what UI should show.
  Future<String> get effectiveBaseUrl async {
    await _baseUrlLoaded;
    return _baseUrl;
  }

  bool get usesDefaultBaseUrl => _baseUrl == defaultBaseUrl;

  /// Switches server for the next requests; null goes back to the default.
  /// Persisting the choice is up to the caller.
  void setBaseUrl(String? url) => _baseUrl = url ?? defaultBaseUrl;

  /// Trims [input], drops trailing slashes and assumes https:// when no
  /// scheme is given; null if it isn't an http(s) URL with a host.
  static String? normalizeBaseUrl(String input) {
    var url = input.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url.isNotEmpty && !url.contains('://')) url = 'https://$url';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return null;
    }
    return url;
  }

  /// Checks that [baseUrl] answers like an NTAKO backend: an unauthenticated
  /// pull must come back as 401 with a JSON error. Returns null when it does,
  /// otherwise a message for the user.
  static Future<String?> checkServer(String baseUrl) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (_) => true,
      ),
    );
    try {
      final resp = await dio
          .get<Object>('$baseUrl/sync/pull')
          .timeout(const Duration(seconds: 30));
      final data = resp.data;
      if (resp.statusCode == 401 && data is Map && data['error'] is String) {
        return null;
      }
      if (resp.statusCode == 404) {
        return 'Nessun backend NTAKO a questo indirizzo (HTTP 404). '
            'Controlla il percorso: di solito finisce con /api.';
      }
      return 'Il server risponde, ma non come un backend NTAKO '
          '(HTTP ${resp.statusCode}).';
    } on DioException catch (e) {
      return 'Server non raggiungibile: ${e.error ?? e.message ?? e.type.name}';
    } catch (e) {
      return 'Server non raggiungibile: $e';
    } finally {
      dio.close();
    }
  }

  Future<void> _prepare(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // handler.next must run whatever happens: an exception thrown in an async
    // interceptor never reaches Dio, and the request would hang forever (an
    // endless spinner on the login screen). Login/register need no token.
    await _baseUrlLoaded;
    options.baseUrl = _baseUrl;
    if (!options.path.startsWith('/auth/')) {
      try {
        final token = await _secureStorage.getToken().timeout(
          const Duration(seconds: 5),
        );
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
      } catch (e) {
        debugPrint('[ApiClient] reading the token failed: $e');
      }
    }
    handler.next(options);
  }

  void _handleError(DioException e, ErrorInterceptorHandler handler) {
    if (e.response?.statusCode == 401 &&
        !e.requestOptions.path.startsWith('/auth/')) {
      // Token expired or invalid — clear local auth so UI redirects to login
      _secureStorage.clearAuth().ignore();
    }
    handler.next(e);
  }

  /// Upper bound for a whole request, whatever stage it is stuck in: the UI
  /// must always get an answer, never an endless spinner.
  static const _requestDeadline = Duration(seconds: 30);

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final resp = await _withDeadline(
      path,
      _dio.post<Map<String, dynamic>>(path, data: data),
    );
    return resp.data!;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final resp = await _withDeadline(
      path,
      _dio.get<Map<String, dynamic>>(path, queryParameters: params),
    );
    return resp.data!;
  }

  Future<T> _withDeadline<T>(String path, Future<T> request) => request.timeout(
    _requestDeadline,
    onTimeout: () => throw DioException.receiveTimeout(
      timeout: _requestDeadline,
      requestOptions: RequestOptions(baseUrl: _baseUrl, path: path),
    ),
  );
}
