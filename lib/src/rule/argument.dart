// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../chunk.dart';
import 'rule.dart';

/// Base class for a rule that handles argument or parameter lists.
abstract class ArgumentRule extends Rule {
  /// The chunks prior to each positional argument.
  final List<Chunk?> _arguments = [];

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

  /// If true, then inner rules that are written will force this rule to split.
  ///
  /// Temporarily disabled while writing collection arguments so that they can
  /// be multi-line without forcing the whole argument list to split.
  bool _trackInnerRules = true;

  /// Don't split when an inner collection rule splits.
  @override
  bool get splitsOnInnerRules => _trackInnerRules;

  ArgumentRule._(this._leadingCollections, this._trailingCollections);

  /// Remembers [chunk] as containing the split that occurs right before an
  /// argument in the list.
  void beforeArgument(Chunk? chunk) {
    _arguments.add(chunk);
  }

  /// Disables tracking inner rules while a collection argument is written.
  void disableSplitOnInnerRules() {
    assert(_trackInnerRules == true);
    _trackInnerRules = false;
  }

  /// Re-enables tracking inner rules.
  void enableSplitOnInnerRules() {
    assert(_trackInnerRules == false);
    _trackInnerRules = true;
  }
}

/// Rule for handling positional argument lists.
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
class PositionalRule extends ArgumentRule {
  /// Creates a new rule for a positional argument list.
  ///
  /// If [collectionRule] is given, it is the rule used to split the collection
  /// arguments in the list.
  PositionalRule(Rule? collectionRule,
      {required int argumentCount,
      int leadingCollections = 0,
      int trailingCollections = 0})
      : super._(leadingCollections, trailingCollections) {
    // Splitting before the first argument, so don't let the collections split
    // internally.
    if (leadingCollections > 0) {
      addConstraint(1, collectionRule!, Rule.unsplit);
    }

    // Only split before the non-collection arguments. This case only comes
    // into play when we do want to split the collection, so force that here.
    if (leadingCollections > 0 || trailingCollections > 0) {
      addConstraint(argumentCount + 1, collectionRule!, 1);
    }
  }

  @override
  int get numValues {
    // Can split before any one argument or none.
    var result = _arguments.length + 1;

    // If there are multiple arguments, can split before all of them.
    if (_arguments.length > 1) result++;

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

  @override
  bool isSplitAtValue(int value, Chunk chunk) {
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

  /// Builds any constraints from this positional argument rule onto the [rule]
  /// used for the subsequent named arguments in the same argument list.
  ///
  /// The [rule] is normally a [NamedRule] but [PositionalRule] is also used for
  /// the property accesses at the beginning of a call chain, in which case this
  /// is just a [SimpleRule].
  void addNamedArgsConstraints(Rule rule) {
    // If the positional args are one-per-line, the named args are too.
    constrainWhenFullySplit(rule);

    // Otherwise, if there is any split in the positional arguments, don't
    // allow the named arguments on the same line as them.
    addRangeConstraint(1, fullySplitValue, rule, Rule.mustSplit);
  }

  @override
  String toString() => 'Pos${super.toString()}';
}

/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * Do not split at all.
/// * Split only before first argument.
/// * Split before all arguments.
class NamedRule extends ArgumentRule {
  @override
  int get numValues => 3;

  NamedRule(
      Rule? collectionRule, int leadingCollections, int trailingCollections)
      : super._(leadingCollections, trailingCollections) {
    if (leadingCollections > 0 || trailingCollections > 0) {
      // Split only before the first argument. Don't allow the collections to
      // split.
      addConstraint(1, collectionRule!, Rule.unsplit);
    }
  }

  @override
  bool isSplitAtValue(int value, Chunk chunk) {
    // Move all arguments to the second line as a unit.
    if (value == 1) return chunk == _arguments.first;

    // Otherwise, split before all arguments.
    return true;
  }

  @override
  String toString() => 'Named${super.toString()}';
}
