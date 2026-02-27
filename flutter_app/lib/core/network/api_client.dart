import 'package:dio/dio.dart';
import '../storage/secure_storage.dart';

class ApiClient {
  // Inject at build time: --dart-define=API_BASE_URL=https://yourserver.com/api
  // Default for local dev with Flutter web
  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080/api',
  );

  final Dio _dio;
  final SecureStorageService _secureStorage;

  ApiClient(this._secureStorage)
      : _dio = Dio(
          BaseOptions(
            baseUrl: _baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: _attachToken,
        onError: _handleError,
      ),
    );
  }

  Future<void> _attachToken(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _secureStorage.getToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  void _handleError(DioException e, ErrorInterceptorHandler handler) {
    if (e.response?.statusCode == 401) {
      // Token expired or invalid — clear local auth so UI redirects to login
      _secureStorage.clearAuth();
    }
    handler.next(e);
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final resp = await _dio.post<Map<String, dynamic>>(path, data: data);
    return resp.data!;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: params,
    );
    return resp.data!;
  }
}
