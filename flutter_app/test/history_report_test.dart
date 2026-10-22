import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntako_timer/core/database/app_database.dart';
import 'package:ntako_timer/features/backup/backup_service.dart';
import 'package:ntako_timer/features/history/history_report.dart';

final now = DateTime(2026, 10, 21, 18, 30); // a Wednesday

void main() {
  group('periods', () {
    (DateTime, DateTime) range(HistoryPeriod p, {DateTime? first}) =>
        HistoryFilters(period: p).range(now, firstSession: first);

    test('resolve to [start, end) day boundaries', () {
      expect(range(HistoryPeriod.today), (
        DateTime(2026, 10, 21),
        DateTime(2026, 10, 22),
      ));
      expect(range(HistoryPeriod.yesterday), (
        DateTime(2026, 10, 20),
        DateTime(2026, 10, 21),
      ));
      expect(range(HistoryPeriod.week), (
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ));
      expect(range(HistoryPeriod.lastWeek), (
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
      ));
      expect(range(HistoryPeriod.month), (
        DateTime(2026, 10),
        DateTime(2026, 11),
      ));
      expect(range(HistoryPeriod.lastMonth), (
        DateTime(2026, 9),
        DateTime(2026, 10),
      ));
      expect(range(HistoryPeriod.year), (DateTime(2026), DateTime(2027)));
      expect(range(HistoryPeriod.lastYear), (DateTime(2025), DateTime(2026)));
      expect(range(HistoryPeriod.all, first: DateTime(2025, 11, 4, 9, 30)), (
        DateTime(2025, 11, 4),
        DateTime(2026, 10, 22),
      ));
    });

    test('custom range includes its last day', () {
      final f = HistoryFilters(
        period: HistoryPeriod.custom,
        customFrom: DateTime(2026, 10, 1),
        customTo: DateTime(2026, 10, 21),
      );
      expect(f.range(now), (DateTime(2026, 10, 1), DateTime(2026, 10, 22)));
    });

    test('auto grouping follows the length of the range', () {
      const f = HistoryFilters();
      expect(
        f.effectiveGroup(DateTime(2026, 10), DateTime(2026, 11)),
        HistoryGroup.day,
      );
      expect(
        f.effectiveGroup(DateTime(2026, 7), DateTime(2026, 11)),
        HistoryGroup.week,
      );
      expect(
        f.effectiveGroup(DateTime(2026), DateTime(2027)),
        HistoryGroup.month,
      );
      expect(
        const HistoryFilters(
          group: HistoryGroup.week,
        ).effectiveGroup(DateTime(2026), DateTime(2027)),
        HistoryGroup.week,
      );
    });
  });

  group('report', () {
    Session session(
      String id,
      DateTime start,
      int minutes, {
      String? taskId,
      bool open = false,
    }) => Session(
      id: id,
      taskId: taskId,
      type: 'tracking',
      startedAt: start.millisecondsSinceEpoch,
      endedAt: open
          ? null
          : start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
      durationSeconds: minutes * 60,
      isCompleted: !open,
      createdAt: 0,
      isSynced: true,
    );
    Task task(
      String id,
      String title, {
      String? categoryId,
      bool deleted = false,
    }) => Task(
      id: id,
      categoryId: categoryId,
      title: title,
      type: 'tracker',
      isCompleted: false,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: deleted ? 1 : null,
      isSynced: true,
    );
    final categories = {
      'c1': const Category(
        id: 'c1',
        name: 'Lavoro',
        color: '#22c55e',
        createdAt: 0,
        updatedAt: 0,
        isSynced: true,
      ),
      'c2': const Category(
        id: 'c2',
        name: 'Casa',
        color: 'not-a-color',
        createdAt: 0,
        updatedAt: 0,
        isSynced: true,
      ),
    };
    final tasks = {
      't1': task('t1', 'Sviluppo', categoryId: 'c1'),
      't2': task('t2', 'Spesa', categoryId: 'c2'),
      't3': task('t3', 'Vecchio', deleted: true),
    };
    final sessions = [
      session('a', DateTime(2026, 10, 20, 9), 120, taskId: 't1'),
      session('b', DateTime(2026, 10, 20, 14), 60, taskId: 't2'),
      session('c', DateTime(2026, 10, 21, 9), 30, taskId: 't3'),
      session('d', DateTime(2026, 10, 21, 10), 45),
      session('e', DateTime(2026, 10, 21, 11), 999, taskId: 't1', open: true),
      session('f', DateTime(2026, 9, 30, 9), 90, taskId: 't1'),
    ];
    HistoryReport build(HistoryFilters f) => HistoryReport.build(
      sessions: sessions,
      tasks: tasks,
      categories: categories,
      filters: f,
      now: now,
    );

    test('totals, buckets and series for a week', () {
      final r = build(const HistoryFilters(period: HistoryPeriod.week));
      expect(
        r.totalSeconds,
        (120 + 60 + 30 + 45) * 60,
        reason: 'open session excluded',
      );
      expect(r.sessions.map((s) => s.id), ['d', 'c', 'b', 'a']);
      expect(r.activeDays, 2);
      expect(r.bucketLabels, [
        '19 ott',
        '20 ott',
        '21 ott',
        '22 ott',
        '23 ott',
        '24 ott',
        '25 ott',
      ]);
      expect(r.categories.map((c) => c.name), [
        'Casa',
        'Lavoro',
        'Senza categoria',
      ]);
      expect(
        r.categories[0].color,
        neutralColor,
        reason: 'invalid stored color',
      );
      expect(r.categories[1].buckets, [0, 7200, 0, 0, 0, 0, 0]);
      expect(r.categories[2].buckets, [0, 0, 75 * 60, 0, 0, 0, 0]);
      expect(r.tasks.map((t) => '${t.name}/${t.category}'), [
        'Sviluppo/Lavoro',
        'Spesa/Casa',
        'Senza task/Senza categoria',
        'Vecchio/Senza categoria',
      ]);
    });

    test('category, uncategorised and task filters', () {
      expect(
        build(
          const HistoryFilters(period: HistoryPeriod.week, categoryId: 'c1'),
        ).sessions.map((s) => s.id),
        ['a'],
      );
      expect(
        build(
          const HistoryFilters(
            period: HistoryPeriod.week,
            categoryId: noCategory,
          ),
        ).sessions.map((s) => s.id),
        ['d', 'c'],
      );
      expect(
        build(
          const HistoryFilters(period: HistoryPeriod.all, taskId: 't1'),
        ).sessions.map((s) => s.id),
        ['a', 'f'],
      );
    });

    test('more than ten tasks fold into "Altri"', () {
      final many = {for (var i = 0; i < 13; i++) 'x$i': task('x$i', 'T$i')};
      final r = HistoryReport.build(
        sessions: [
          for (var i = 0; i < 13; i++)
            session('s$i', DateTime(2026, 10, 21, 8), 10 + i, taskId: 'x$i'),
        ],
        tasks: many,
        categories: const {},
        filters: const HistoryFilters(period: HistoryPeriod.today),
        now: now,
      );
      expect(r.tasks, hasLength(11));
      expect(r.tasks.first.name, 'T12');
      expect(r.tasks.last.name, 'Altri 3 task');
      expect(r.tasks.last.seconds, (10 + 11 + 12) * 60);
    });
  });

  test('report totals match the Arundo file', () async {
    final file = File('../SHEETEXAMPLE/arundo_import.json');
    if (!file.existsSync()) return;
    final source = file.readAsStringSync();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await BackupService(db).importJson(source);
    final sessions = await db.select(db.sessions).get();
    final tasks = {for (final t in await db.select(db.tasks).get()) t.id: t};
    final cats = {
      for (final c in await db.select(db.categories).get()) c.id: c,
    };

    // Expected values straight from the file (sessions all finished).
    final rows = (jsonDecode(source)['sessions'] as List).cast<Map>();
    final days = {
      for (final r in rows)
        () {
          final d = DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int);
          return '${d.year}-${d.month}-${d.day}';
        }(),
    };
    final seconds = rows.fold<int>(
      0,
      (s, r) => s + (r['duration_seconds'] as int),
    );

    final all = HistoryReport.build(
      sessions: sessions,
      tasks: tasks,
      categories: cats,
      filters: const HistoryFilters(period: HistoryPeriod.all),
      now: DateTime.now(),
    );
    expect(all.totalSeconds, seconds);
    expect(all.sessions, hasLength(rows.length));
    expect(all.activeDays, days.length);
    expect(all.group, HistoryGroup.month);
    expect(
      all.categories.single.buckets.fold<int>(0, (a, b) => a + b),
      seconds,
      reason: 'every session lands in a bucket',
    );
  });
}
