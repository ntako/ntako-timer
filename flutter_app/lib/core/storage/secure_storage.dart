import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _tokenKey = 'jwt_token';
  static const _userIdKey = 'user_id';
  static const _userEmailKey = 'user_email';

  Future<void> saveAuthData({
    required String token,
    required int userId,
    required String email,
  }) async {
    // Sequential writes are required on web: flutter_secure_storage_web
    // generates the AES encryption key lazily on the first write.
    // With concurrent Future.wait writes, all three calls see "key absent"
    // and each generates a different key — only the last survives in
    // localStorage, making the earlier encrypted values undecryptable on
    // the next page load.
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _userIdKey, value: userId.toString());
    await _storage.write(key: _userEmailKey, value: email);
  }

  Future<String?> getToken() => _storage.read(key: _tokenKey);

  Future<int?> getUserId() async {
    final v = await _storage.read(key: _userIdKey);
    return v != null ? int.tryParse(v) : null;
  }

  Future<String?> getUserEmail() => _storage.read(key: _userEmailKey);

  Future<bool> get isLoggedIn async => (await getToken()) != null;

  Future<void> clearAuth() => _storage.deleteAll();
}
