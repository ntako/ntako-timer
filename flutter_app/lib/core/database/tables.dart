import 'package:drift/drift.dart';

class Categories extends Table {
  TextColumn get id => text()(); // UUID generated client-side
  IntColumn get serverId => integer().nullable()();
  TextColumn get name => text()();
  TextColumn get color =>
      text().withDefault(const Constant('#6366f1'))(); // hex color
  IntColumn get createdAt => integer()(); // Unix ms
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()(); // soft delete
  BoolColumn get isSynced =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()(); // UUID generated client-side
  IntColumn get serverId => integer().nullable()();
  TextColumn get categoryId =>
      text().nullable().references(Categories, #id)();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get type =>
      text().withDefault(const Constant('pomodoro'))(); // 'pomodoro' | 'tracker'
  IntColumn get pomodoroGoal =>
      integer().withDefault(const Constant(4))();
  IntColumn get pomodorosDone =>
      integer().withDefault(const Constant(0))();
  BoolColumn get isCompleted =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()(); // Unix ms
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()(); // soft delete
  BoolColumn get isSynced =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Sessions extends Table {
  @override
  String get tableName => 'sessions';

  TextColumn get id => text()(); // UUID
  IntColumn get serverId => integer().nullable()();
  TextColumn get taskId =>
      text().nullable().references(Tasks, #id)();
  TextColumn get type =>
      text()(); // 'work' | 'short_break' | 'long_break' | 'tracking'
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer().nullable()();
  IntColumn get durationSeconds => integer()();
  BoolColumn get isCompleted =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  BoolColumn get isSynced =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
