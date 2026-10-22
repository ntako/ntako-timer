import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntako_timer/core/database/app_database.dart';
import 'package:ntako_timer/core/network/api_client.dart';
import 'package:ntako_timer/features/sync/sync_service.dart';

/// In-memory stand-in for the backend: acknowledges every pushed row and
/// serves the queued pull pages in order.
class FakeApi implements ApiClient {
  final List<Map<String, dynamic>> pullPages = [];
  final List<String> pulledCursors = [];
  final List<Map<String, dynamic>> pushes = [];

  /// Runs while a push is "on the wire", to simulate concurrent local edits.
  Future<void> Function()? duringPush;

  @override
  String get baseUrl => 'http://fake';

  @override
  Future<String> get effectiveBaseUrl async => baseUrl;

  @override
  bool get usesDefaultBaseUrl => true;

  @override
  void setBaseUrl(String? url) {}

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data,
  ) async {
    pushes.add(data);
    await duringPush?.call();
    List<Map<String, dynamic>> ack(String key) => [
          for (final (i, row) in (data[key] as List).indexed)
            {'client_id': (row as Map)['client_id'], 'server_id': i + 1},
        ];
    return {
      'synced_categories': ack('categories'),
      'synced_tasks': ack('tasks'),
      'synced_sessions': ack('sessions'),
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final cursor = params!['cursor'] as String;
    pulledCursors.add(cursor);
    if (pullPages.isNotEmpty) return pullPages.removeAt(0);
    return page(cursor: int.parse(cursor));
  }

  static Map<String, dynamic> page({
    required int cursor,
    bool hasMore = false,
    List<Map<String, dynamic>> tasks = const [],
    List<Map<String, dynamic>> sessions = const [],
  }) =>
      {
        'categories': <dynamic>[],
        'tasks': tasks,
        'sessions': sessions,
        'cursor': cursor,
        'has_more': hasMore,
      };
}

Map<String, dynamic> remoteTask(String id, {int updatedAt = 1000}) => {
      'id': 1,
      'client_id': id,
      'category_client_id': null,
      'title': 'remote $id',
      'description': null,
      'is_completed': 0,
      'created_at': 1000,
      'updated_at': updatedAt,
      'deleted_at': null,
    };

void main() {
  late AppDatabase db;
  late FakeApi api;
  late SyncService sync;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeApi();
    sync = SyncService(db: db, api: api);
  });

  tearDown(() => db.close());

  Future<void> insertLocalTask(String id, {int updatedAt = 1000}) =>
      db.tasksDao.insertTask(
        TasksCompanion.insert(
          id: id,
          title: 'local $id',
          createdAt: 1000,
          updatedAt: updatedAt,
        ),
      );

  test('pull follows has_more and stores the final cursor', () async {
    api.pullPages.addAll([
      FakeApi.page(cursor: 5, hasMore: true, tasks: [remoteTask('a')]),
      FakeApi.page(cursor: 9, tasks: [remoteTask('b')]),
    ]);

    await sync.sync();

    expect(api.pulledCursors, ['0', '5']);
    expect(await db.settingsDao.getValue('sync_cursor'), '9');
    expect(await db.tasksDao.getTaskById('a'), isNotNull);
    expect(await db.tasksDao.getTaskById('b'), isNotNull);

    await sync.sync();
    expect(api.pulledCursors.last, '9');
  });

  test('an edit made while the push is in flight stays unsynced', () async {
    await insertLocalTask('t', updatedAt: 1000);
    api.duringPush = () async {
      api.duringPush = null;
      await db.tasksDao.updateTask(
        const TasksCompanion(
          id: Value('t'),
          title: Value('edited mid-push'),
          updatedAt: Value(2000),
          isSynced: Value(false),
        ),
      );
    };

    await sync.sync();
    expect((await db.tasksDao.getTaskById('t'))!.isSynced, isFalse);

    await sync.sync();
    final pushedTitle = ((api.pushes.last['tasks'] as List).single as Map)['title'];
    expect(pushedTitle, 'edited mid-push');
    expect((await db.tasksDao.getTaskById('t'))!.isSynced, isTrue);
  });

  test('concurrent sync calls are coalesced into one extra round', () async {
    await insertLocalTask('t');
    var inFlight = 0;
    var maxInFlight = 0;
    final callsDuringSync = <Future<void>>[];
    api.duringPush = () async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      if (callsDuringSync.isEmpty) {
        // New edit after the push snapshot, then two more sync requests.
        await insertLocalTask('u', updatedAt: 3000);
        callsDuringSync
          ..add(sync.sync())
          ..add(sync.sync());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      inFlight--;
    };

    await sync.sync();
    await Future.wait(callsDuringSync);

    expect(maxInFlight, 1);
    expect(api.pushes, hasLength(2));
    expect((await db.tasksDao.getTaskById('u'))!.isSynced, isTrue);
  });

  test('a session stopped while its open copy is being pushed is kept',
      () async {
    await db.sessionsDao.insertSession(
      SessionsCompanion.insert(
        id: 's',
        type: 'tracking',
        startedAt: 1000,
        durationSeconds: 0,
        createdAt: 1000,
      ),
    );
    api.duringPush = () async {
      api.duringPush = null;
      await db.sessionsDao.completeSessionWithDuration('s', 61000, 60);
    };
    // The server echoes back the still-open copy it just received.
    api.pullPages.add(FakeApi.page(cursor: 1, sessions: [
      {
        'id': 1,
        'client_id': 's',
        'task_client_id': null,
        'type': 'tracking',
        'started_at': 1000,
        'ended_at': null,
        'duration_seconds': 0,
        'is_completed': 0,
        'created_at': 1000,
      },
    ]));

    await sync.sync();

    final s = (await db.sessionsDao.getSessionById('s'))!;
    expect(s.endedAt, 61000);
    expect(s.durationSeconds, 60);
    expect(s.isSynced, isFalse);

    await sync.sync();
    final pushed = (api.pushes.last['sessions'] as List).single as Map;
    expect(pushed['ended_at'], 61000);
    expect((await db.sessionsDao.getSessionById('s'))!.isSynced, isTrue);
  });
}
