// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.cost;

/// Constants for the cost heuristics used to determine which set of splits is
/// most desirable.
///
/// These are carefully balanced. Adjust them carefully lest the whole hanging
/// mobile fall down on you.
class Cost {
  /// The best cost, meaning the rule has been fully satisfied.
  static const FREE = 0;

  static const BEFORE_EXTENDS = 3;
  static const BEFORE_IMPLEMENTS = 2;
  static const BEFORE_WITH = 1;

  // TODO(rnystrom): Is this correct? Should it be greater for longer
  // collections?
  /// Splitting a list or map literal.
  static const COLLECTION_LITERAL = 1;

  /// After each variable in a variable declaration list.
  static const DECLARATION = 1;

  /// Between adjacent string literals.
  static const ADJACENT_STRINGS = 10;

  /// The span to try to keep the right-hand side of an assignment/initializer
  /// together.
  static const ASSIGNMENT_SPAN = 10;

  /// Splitting before "." in a method call.
  static const BEFORE_PERIOD = 20;

  /// After a "=>".
  static const ARROW = 20;

  /// The cost of failing to keep all arguments on one line.
  ///
  /// This is in addition to the cost of splitting after any specific argument.
  static const SPLIT_ARGUMENTS = 20;

  /// After the ":" in a conditional expression.
  static const AFTER_COLON = 20;

  /// The cost of splitting before any argument (including the first) in an
  /// argument list.
  ///
  /// Successive arguments decrement from here so that it prefers to split over
  /// later arguments.
  static const BEFORE_ARGUMENT = 30;

  /// After the "?" in a conditional expression.
  static const AFTER_CONDITION = 30;

  /// After a "=" both for assignment and initialization.
  static const ASSIGNMENT = 40;

  // TODO(rnystrom): Different costs for different operators.
  /// The cost of splitting after a binary operator.
  static const BINARY_OPERATOR = 80;

  /// The cost of a single character that goes past the page limit.
  static const OVERFLOW_CHAR = 10000;
}
