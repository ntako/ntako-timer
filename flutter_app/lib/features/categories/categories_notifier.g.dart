// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'categories_notifier.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$activeCategoriesHash() => r'7d9cd687ec71c7c9c4d946e2ccfc05e69c9baa85';

/// Live stream di categorie attive (non eliminate).
///
/// Copied from [activeCategories].
@ProviderFor(activeCategories)
final activeCategoriesProvider =
    AutoDisposeStreamProvider<List<Category>>.internal(
      activeCategories,
      name: r'activeCategoriesProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$activeCategoriesHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ActiveCategoriesRef = AutoDisposeStreamProviderRef<List<Category>>;
String _$categoriesNotifierHash() =>
    r'1aed2291ad2588775721277d240d187684ee7ae3';

/// See also [CategoriesNotifier].
@ProviderFor(CategoriesNotifier)
final categoriesNotifierProvider =
    AutoDisposeNotifierProvider<CategoriesNotifier, void>.internal(
      CategoriesNotifier.new,
      name: r'categoriesNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$categoriesNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$CategoriesNotifier = AutoDisposeNotifier<void>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
