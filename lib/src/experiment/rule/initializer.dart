// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../chunk.dart';
import 'rule.dart';

/// Rule for splitting a constructor initializer list and the leading `:`. The
/// parameters and initializers are constrained so that only a few combinations
/// of splits are allowed.
///
/// The values for this rule are:
///
/// *   `0`: No splits at all. Only allowed when the parameters do not split.
///
///         SomeClass(param) : a = 1, b = 2;
///
/// *   `1`: Split before the `:` and between the initializers. Only allowed
///      when the parameters do not split.
///
///         SomeClass(param)
///           : a = 1,
///             b = 2;
///
/// *   `2`: Split between the initializers but not before the `:`. Only
///     allowed when the parameters do split. If there are no parameters, this
///     value is excluded.
///
///         SomeClass(
///           param
///         ) : a = 1,
///             b = 2;
///
/// If there are no constructor parameters, then 2 can't be chosen.
class InitializerRule extends Rule {
  final bool _hasParameters;

  /// Whether the parameter list has an `]` or `}` closing delimiter.
  final bool _hasRightDelimiter;

  late final Chunk _colonChunk;

  InitializerRule(Rule? parameterRule, {required bool hasRightDelimiter})
      : _hasParameters = parameterRule != null,
        _hasRightDelimiter = hasRightDelimiter {
    // Wire up the constraints between the parameters and initializers.
    if (parameterRule != null) {
      // Can't keep the initializers inline if the parameters split.
      parameterRule.addConstraint(1, this, Rule.mustSplit);

      // Can only keep the initializers on one line if the parameters are.
      addConstraint(0, parameterRule, 0);

      // Can only split before the ":" if the parameters are on one line.
      addConstraint(1, parameterRule, 0);

      // Can only split before the initializers but not the ":" when the
      // parameters split and the ")" is on the next line preceding the ":".
      addConstraint(2, parameterRule, 1);
    }
  }

  void bindColon(Chunk chunk) {
    _colonChunk = chunk;
  }

  @override
  int get numValues => _hasParameters ? 3 : 2;

  /// When an initializer splits, we have to split the initializer list, but
  /// either 1 or 2 is a valid way to do it.
  @override
  int? get splitOnInnerRules => Rule.mustSplit;

  @override
  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case Rule.unsplit:
        return false;
      case 1:
        return true;
      case 2:
        // Split on everything except the ":".
        return chunk != _colonChunk;
      default:
        throw ArgumentError.value(value, 'value');
    }
  }

  /// Insert an extra space of indentation on subsequent initializers if the
  /// parameter list has an optional or named section and the parameter list
  /// splits.
  ///
  ///     Constructor({parameter})
  ///       : initializer1 = 1,
  ///         initializer2 = 2;
  ///     ^^^^ +4
  ///
  ///     Constructor({
  ///       parameter
  ///     }) : initializer1 = 1,
  ///          initializer2 = 2;
  ///     ^^^^^ +5
  ///
  /// We want subsequent initializers to line up with the first one. If the
  /// parameters have an optional or named section, then the position of the
  /// first initializer will be +5 if the parameters split but only +4 if they
  /// don't.
  @override
  int chunkIndent(int value, Chunk chunk) {
    if (value == 1 && chunk == _colonChunk) return -2;
    return 0;
  }

  /// How much indentation a [NestingLevel] bound to this rule should add.
  ///
  /// This is used when the depth of a nesting level is specific to certain
  /// rule values. Currently, it's used for argument lists, where arguments are
  /// indented at some split values but not others.
  @override
  int nestingIndent(int value, {required bool isUsed}) {
    switch (value) {
      case Rule.unsplit:
        return 0;
      case 1:
        return 4;
      case 2:
        return _hasRightDelimiter ? 5 : 4;
      default:
        throw ArgumentError.value(value, 'value');
    }
  }

  @override
  String toString() => 'Init${super.toString()}';
}
