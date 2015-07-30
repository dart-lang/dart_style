// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.rule.argument;

import '../chunk.dart';
import 'rule.dart';

/// Base class for a rule that handles argument or parameter lists.
abstract class ArgumentRule extends Rule {
  /// The rule used to split collections in the argument list, if any.
  final Rule _collectionRule;

  /// If true, then inner rules that are written will force this rule to split.
  ///
  /// Temporarily disabled while writing collectio arguments so that they can be
  /// multi-line without forcing the whole argument list to split.
  bool _trackInnerRules = true;

  /// Don't split when an inner collection rule splits.
  bool get splitsOnInnerRules => _trackInnerRules;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [_collectionRule] is given, it is the rule used to split the
  /// collections in the list.
  ArgumentRule(this._collectionRule);

  /// Called before a collection argument is written.
  ///
  /// Disables tracking inner rules while a collection argument is written.
  void beforeCollection() {
    assert(_trackInnerRules == true);
    _trackInnerRules = false;
  }

  /// Called after a collection argument is complete.
  ///
  /// Re-enables tracking inner rules.
  void afterCollection() {
    assert(_trackInnerRules == false);
    _trackInnerRules = true;
  }
}

/// Base class for a rule for handling positional argument lists.
abstract class PositionalRule extends ArgumentRule {
  /// The chunks prior to each positional argument.
  final List<Chunk> _arguments = [];

  /// If there are named arguments following these positional ones, this will
  /// be their rule.
  Rule _namedArgsRule;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [collectionRule] is given, it is the rule used to split the collection
  /// arguments in the list.
  PositionalRule(Rule collectionRule) : super(collectionRule);

  /// Remembers [chunk] as containing the split that occurs right before an
  /// argument in the list.
  void beforeArgument(Chunk chunk) {
    _arguments.add(chunk);
  }

  /// Remembers that [rule] is the [NamedArgsRule] immediately following this
  /// positional argument list.
  void setNamedArgsRule(NamedRule rule) {
    _namedArgsRule = rule;
  }

  /// Constrains the named argument list to at least move to the next line if
  /// there are any splits in the positional arguments. Prevents things like:
  ///
  ///      function(
  ///          argument,
  ///          argument, named: argument);
  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    // Handle the relationship between the positional and named args.
    if (other == _namedArgsRule) {
      // If the positional args are one-per-line, the named args are too.
      if (value == fullySplitValue) return _namedArgsRule.fullySplitValue;

      // Otherwise, if there is any split in the positional arguments, don't
      // allow the named arguments on the same line as them.
      if (value != 0) return -1;
    }

    return null;
  }
}

/// Split rule for a call with a single positional argument (which may or may
/// not be a collection argument.)
class SinglePositionalRule extends PositionalRule {
  int get numValues => 2;

  /// If there is only a single non-collection argument, allow it to split
  /// internally without forcing a split before the argument.
  final bool splitsOnInnerRules;

  bool hack = false;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [collectionRule] is given, it is the rule used to split the
  /// collections in the list. If [splitsOnInnerRules] is `true`, then we will
  /// split before the argument if the argument itself contains a split.
  SinglePositionalRule(Rule collectionRule, {bool splitsOnInnerRules})
      : super(collectionRule),
        splitsOnInnerRules =
            splitsOnInnerRules != null ? splitsOnInnerRules : false;

  bool isSplit(int value, Chunk chunk) => value == 1;

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _collectionRule) return null;

    // If we aren't splitting any args, we can split the collection.
    if (value == 0) return null;

    // We are splitting before a collection, so don't let it split internally.
    return 0;
  }

  String toString() => "1Pos${super.toString()}";
}

/// Split rule for a call with more than one positional argument.
///
/// The number of values is based on the number of arguments and whether or not
/// there are bodies. The first two values are always:
///
/// * 0: Do not split at all.
/// * 1: Split only before the first argument.
///
/// Then there is a value for each argument, to split before that argument.
/// These values work back to front. So, for a two-argument list, value 2 splits
/// after the second argument and value 3 splits after the first.
///
/// Then there is a value that splits before every argument.
///
/// Finally, if there are collection arguments, there is another value that
/// splits before all of the non-collection arguments, but does not split
/// before the collections, so that they can split internally.
class MultiplePositionalRule extends PositionalRule {
  /// The number of leading collection arguments.
  ///
  /// This and [_trailingCollections] cannot both be positive. If every
  /// argument is a collection, this will be [_arguments.length] and
  /// [_trailingCollections] will be 0.
  final int _leadingCollections;

  /// The number of trailing collections.
  ///
  /// This and [_leadingCollections] cannot both be positive.
  final int _trailingCollections;

  int get numValues {
    // Can split before any one argument, none, or all.
    var result = 2 + _arguments.length;

    // When there are collection arguments, there are two ways we can split on
    // "all" arguments:
    //
    // - Split on just the non-collection arguments, and force the collection
    //   arguments to split internally.
    // - Split on all of them including the collection arguments, and do not
    //   allow the collection arguments to split internally.
    if (_leadingCollections > 0 || _trailingCollections > 0) result++;

    return result;
  }

  MultiplePositionalRule(
      Rule collectionRule, this._leadingCollections, this._trailingCollections)
      : super(collectionRule);

  String toString() => "*Pos${super.toString()}";

  bool isSplit(int value, Chunk chunk) {
    // Don't split at all.
    if (value == 0) return false;

    // Split only before the first argument. Keep the entire argument list
    // together on the next line.
    if (value == 1) return chunk == _arguments.first;

    // Split before a single argument. Try later arguments before earlier ones
    // to try to keep as much on the first line as possible.
    if (value <= _arguments.length) {
      var argument = _arguments.length - value + 1;
      return chunk == _arguments[argument];
    }

    // Only split before the non-collection arguments.
    if (value == _arguments.length + 1) {
      for (var i = 0; i < _leadingCollections; i++) {
        if (chunk == _arguments[i]) return false;
      }

      for (var i = _arguments.length - _trailingCollections;
          i < _arguments.length;
          i++) {
        if (chunk == _arguments[i]) return false;
      }

      return true;
    }

    // Split before all of the arguments, even the collections.
    return true;
  }

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _collectionRule) return null;

    // If we aren't splitting any args, we can split the collection.
    if (value == 0) return null;

    // Split only before the first argument.
    if (value == 1) {
      if (_leadingCollections > 0) {
        // We are splitting before a collection, so don't let it split
        // internally.
        return 0;
      } else {
        // The split is outside of the collections so they can split or not.
        return null;
      }
    }

    // Split before a single argument. If it's in the middle of the collection
    // arguments, don't allow them to split.
    if (value <= _arguments.length) {
      var argument = _arguments.length - value + 1;
      if (argument < _leadingCollections) return 0;
      if (argument >= _arguments.length - _trailingCollections) return 0;

      return null;
    }

    // Only split before the non-collection arguments. This case only comes into
    // play when we do want to split the collection, so force that here.
    if (value == _arguments.length + 1) return 1;

    // Split before all of the arguments, even the collection, so don't let
    // them split.
    return 0;
  }
}

/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2: Split before all arguments, including the first.
class NamedRule extends ArgumentRule {
  /// The chunk prior to the first named argument.
  Chunk _first;

  int get numValues => 3;

  NamedRule(Rule collectionRule) : super(collectionRule);

  void beforeArguments(Chunk chunk) {
    assert(_first == null);
    _first = chunk;
  }

  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case 0:
        return false;
      case 1:
        return chunk == _first;
      case 2:
        return true;
    }

    throw "unreachable";
  }

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _collectionRule) return null;

    // If we aren't splitting any args, we can split the collection.
    if (value == 0) return null;

    // Split before all of the arguments, even the collections, so don't let
    // them split.
    return 0;
  }

  String toString() => "Named${super.toString()}";
}
