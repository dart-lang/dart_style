// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Constants for the cost heuristics used to determine which set of splits is
/// most desirable.
class Cost {
  /// The cost of splitting after the `=>` in a lambda or arrow-bodied member.
  ///
  /// We make this zero because there is already a span around the entire body
  /// and we generally do prefer splitting after the `=>` over other places.
  static const arrow = 0;

  /// The default cost.
  ///
  /// This isn't zero because we want to ensure all splitting has *some* cost,
  /// otherwise, the formatter won't try to keep things on one line at all.
  /// Most splits and spans use this. Greater costs tend to come from a greater
  /// number of nested spans.
  static const normal = 1;

  /// Splitting after a "=".
  static const assign = 2;

  /// Splitting inside the brackets of a list with only one element.
  static const singleElementList = 2;

  /// Splitting on the "." in a named constructor.
  static const constructorName = 4;

  /// Splitting a `[...]` index operator.
  static const index = 4;

  /// Splitting before a type argument or type parameter.
  static const typeArgument = 4;

  /// Split between a formal parameter name and its type.
  static const parameterType = 4;
}

/// Constants for the number of spaces for various kinds of indentation.
class Indent {
  /// The number of spaces in a block or collection body.
  static const block = 2;

  /// How much wrapped cascade sections indent.
  static const cascade = 2;

  /// The number of spaces in a single level of expression nesting.
  static const expression = 4;

  /// Argument lists get no indentation because the final `)` shouldn't be
  /// indented.
  ///
  /// The arguments on preceding lines get +2 indentation on a per-chunk basis.
  static const argumentList = 0;
}
