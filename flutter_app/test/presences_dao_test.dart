import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workadoro/core/database/app_database.dart';

PresencesCompanion stay(String id, {int at = 1000}) =>
    PresencesCompanion.insert(
      id: id,
      placeId: 'office',
      placeName: 'Ufficio',
      method: 'wifi',
      enteredAt: at,
      lastSeenAt: at,
    );

void main() {
  test('upgrading from schema 3 keeps the data and adds presences', () async {
    final dir = await Directory.systemTemp.createTemp('workadoro_db');
    final file = File('${dir.path}/db.sqlite');
    addTearDown(() => dir.delete(recursive: true));

    // A database as version 3 left it: no presences table.
    var db = AppDatabase(NativeDatabase(file));
    await db
        .into(db.sessions)
        .insert(
          SessionsCompanion.insert(
            id: 's1',
            type: 'tracking',
            startedAt: 1,
            durationSeconds: 60,
            createdAt: 1,
          ),
        );
    await db.customStatement('DROP TABLE presences');
    await db.customStatement('PRAGMA user_version = 3');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.select(db.sessions).get(), hasLength(1));
    await db.presencesDao.insertPresence(stay('p1'));
    expect(await db.presencesDao.getOpen(), hasLength(1));
  });

  test('a stay seen again while being pushed stays unsynced', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = db.presencesDao;

    await dao.insertPresence(stay('p1'));
    final pushed = (await dao.getUnsynced()).single;
    await dao.markSeen('p1', 2000); // detection during the push
    await dao.markSynced(pushed, 7);
    expect(await dao.getUnsynced(), hasLength(1));

    final again = (await dao.getUnsynced()).single;
    await dao.markSynced(again, 7);
    expect(await dao.getUnsynced(), isEmpty);

    await dao.closeStay('p1', 3000);
    final closed = (await dao.getUnsynced()).single;
    expect(closed.exitedAt, 3000);
    expect(closed.lastSeenAt, 3000);
    expect(await dao.getOpen(), isEmpty);
  });
}
