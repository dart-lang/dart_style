// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Merges a [defaults] options set with an [overrides] options set using
/// simple override semantics, suitable for merging two configurations where
/// one defines default values that are added to (and possibly overridden) by an
/// overriding one.
///
/// The merge rules are:
///
/// *   Lists are concatenated without duplicates.
/// *   A list of strings is promoted to a map of strings to `true` when merged
///     with another map of strings to booleans. For example `['opt1', 'opt2']`
///     is promoted to `{'opt1': true, 'opt2': true}`.
/// *   Maps unioned. When both have the same key, the corresponding values are
///     merged, recursively.
/// *   Otherwise, a non-`null` override replaces a default value.
Object? merge(Object? defaults, Object? overrides) {
  return switch ((defaults, overrides)) {
    (List(isAllStrings: true) && var list, Map(isToBools: true)) =>
      merge(_promoteList(list), overrides),
    (Map(isToBools: true), List(isAllStrings: true) && var list) =>
      merge(defaults, _promoteList(list)),
    (Map defaultsMap, Map overridesMap) => _mergeMap(defaultsMap, overridesMap),
    (List defaultsList, List overridesList) =>
      _mergeList(defaultsList, overridesList),
    (_, null) =>
      // Default to override, unless the overriding value is `null`.
      defaults,
    _ => overrides,
  };
}

/// Promote a list of strings to a map of those strings to `true`.
Map<Object?, Object?> _promoteList(List<Object?> list) {
  return {for (var element in list) element: true};
}

/// Merge lists, avoiding duplicates.
List<Object?> _mergeList(List<Object?> defaults, List<Object?> overrides) {
  // Add them both to a set so that the overrides replace the defaults.
  return {...defaults, ...overrides}.toList();
}

/// Merge maps (recursively).
Map<Object?, Object?> _mergeMap(
    Map<Object?, Object?> defaults, Map<Object?, Object?> overrides) {
  var merged = {...defaults};

  overrides.forEach((key, value) {
    merged.update(key, (defaultValue) => merge(defaultValue, value),
        ifAbsent: () => value);
  });

  return merged;
}

extension<T> on List<T> {
  bool get isAllStrings => every((e) => e is String);
}

extension<K, V> on Map<K, V> {
  bool get isToBools => values.every((v) => v is bool);
}
