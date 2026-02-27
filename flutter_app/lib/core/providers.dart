import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'database/app_database.dart';
import 'network/api_client.dart';
import 'storage/secure_storage.dart';

part 'providers.g.dart';

@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) => AppDatabase();

@Riverpod(keepAlive: true)
SecureStorageService secureStorage(SecureStorageRef ref) =>
    SecureStorageService();

@Riverpod(keepAlive: true)
ApiClient apiClient(ApiClientRef ref) =>
    ApiClient(ref.watch(secureStorageProvider));
