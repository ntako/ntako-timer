// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tasks_notifier.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$activeTasksHash() => r'd48c03b063042a845f8fa699222353235ad3e28d';

/// Live stream di task attivi (non eliminati), ordinati dal più recente.
///
/// Copied from [activeTasks].
@ProviderFor(activeTasks)
final activeTasksProvider = AutoDisposeStreamProvider<List<Task>>.internal(
  activeTasks,
  name: r'activeTasksProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$activeTasksHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ActiveTasksRef = AutoDisposeStreamProviderRef<List<Task>>;
String _$taskTotalsHash() => r'1ef1dcdc50de87c9c98cc9fb11c3e5b16565d4d0';

/// Live map of taskId → total tracked seconds (completed sessions only).
///
/// Copied from [taskTotals].
@ProviderFor(taskTotals)
final taskTotalsProvider = AutoDisposeStreamProvider<Map<String, int>>.internal(
  taskTotals,
  name: r'taskTotalsProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$taskTotalsHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef TaskTotalsRef = AutoDisposeStreamProviderRef<Map<String, int>>;
String _$tasksNotifierHash() => r'8daa11f799066b92237c520881905a943146a10a';

/// See also [TasksNotifier].
@ProviderFor(TasksNotifier)
final tasksNotifierProvider =
    AutoDisposeNotifierProvider<TasksNotifier, void>.internal(
      TasksNotifier.new,
      name: r'tasksNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$tasksNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$TasksNotifier = AutoDisposeNotifier<void>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
