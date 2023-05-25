// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../chunk.dart';
import '../constants.dart';
import 'rule.dart';

/// Rule for an argument list that contains some block-like argument, as in:
///
/// ```
/// test('description', () {
///   ...
/// });
/// ```
abstract class ArgumentListRule extends Rule with TrackInnerRulesMixin {
  late final Chunk _rightParenthesisChunk;

  void bindRightParenthesis(Chunk chunk) {
    _rightParenthesisChunk = chunk;
  }

  @override
  int chunkIndent(int value, Chunk chunk) {
    // Don't indent the closing ")"
    if (chunk == _rightParenthesisChunk) return 0;

    // Indent other arguments.
    return Indent.block;
  }

  @override
  String toString() => 'Args${super.toString()}';
}

/// Rule for an argument list that contains a block-like collection argument,
/// as in:
///
/// ```
/// function(argument, [
///   element,
///   element
/// ]);
/// ```
///
/// This rule contains four values:
///
/// 0.  Don't split the arguments or the block argument contents:
///
///     ```
///     function(argument, [element, element]);
///     ```
///
/// 1. Split the block argument contents, but not the arguments.
///
///     ```
///     function(argument, [
///       element,
///       element
///     ]);
///     ```
///
/// 2. Split the arguments but not the block argument contents.
///
///     ```
///     function(
///       argument,
///       [element, element]
///     );
///     ```
///
/// 3. Split the arguments and the block argument contents.
///
///     ```
///     function(
///       argument,
///       [
///         element,
///         element
///       ]
///     );
///     ```
class CollectionArgumentListRule extends ArgumentListRule {
  late final Chunk _blockChunk;

  void bindBlock(Chunk chunk) {
    _blockChunk = chunk;
  }

  @override
  int get numValues => 4;

  @override
  bool isSplitAtValue(int value, Chunk chunk) {
    switch (value) {
      case 0:
        return false;
      case 1:
        return chunk == _blockChunk;
      case 2:
        return chunk != _blockChunk;
      default:
        return true;
    }
  }

  @override
  int chunkIndent(int value, Chunk chunk) {
    // Only indent the body of the block argument if the arguments split.
    if (chunk == _blockChunk) {
      return value == 3 ? Indent.block : 0;
    }

    return super.chunkIndent(value, chunk);
  }
}

/// Rule for an argument list that contains a block-like function argument, as
/// in:
///
/// ```
/// function(argument, () {
///   ;
/// });
/// ```
///
/// Since the function body always splits, the rule only has two values:
///
/// 0. Split the function body, but not the arguments.
///
///     ```
///     function(argument, () {
///       ;
///     });
///     ```
///
/// 1. Split the arguments and the function body.
///
///     ```
///     function(
///       argument,
///       () {
///         ;
///       }
///     );
///     ```
class FunctionArgumentListRule extends ArgumentListRule {}

// TODO: Remove.
/// Base class for a rule that handles argument or parameter lists.
abstract class ArgumentRule extends Rule with TrackInnerRulesMixin {
  /// The chunks prior to each positional argument.
  final List<Chunk?> _arguments = [];

  /// Remembers [chunk] as containing the split that occurs right before an
  /// argument in the list.
  void beforeArgument(Chunk? chunk) {
    _arguments.add(chunk);
  }
}

// TODO: This shouldn't be needed any more.
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

  /// Creates a new rule for a positional argument list.
  ///
  /// [argumentCount] is the number of arguments that will be added to the rule
  /// by later calls to [beforeArgument()].
  ///
  /// If [collectionRule] is given, it is the rule used to split the collection
  /// arguments in the list. It must be provided if [leadingCollections] or
  /// [trailingCollections] is non-zero.
  PositionalRule(Rule? collectionRule,
      {required int argumentCount,
      int leadingCollections = 0,
      int trailingCollections = 0})
      : _leadingCollections = leadingCollections,
        _trailingCollections = trailingCollections {
    // Don't split inside collections if there are leading collections and
    // we split before the first argument.
    if (leadingCollections > 0) {
      addConstraint(1, collectionRule!, Rule.unsplit);
    }

    // If we're only splitting before the non-collection arguments, the
    // intent is to split inside the collections, so force that here.
    if (leadingCollections > 0 || trailingCollections > 0) {
      addConstraint(argumentCount + 1, collectionRule!, 1);
    }

    // Split before a single argument. If it's in the middle of the collection
    // arguments, don't allow them to split.
    for (var argument = 0; argument < leadingCollections; argument++) {
      var value = argumentCount - argument + 1;
      addConstraint(value, collectionRule!, Rule.unsplit);
    }

    for (var argument = argumentCount - trailingCollections;
        argument < argumentCount;
        argument++) {
      var value = argumentCount - argument + 1;
      addConstraint(value, collectionRule!, Rule.unsplit);
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
    addConstraint(fullySplitValue, rule, Rule.fullSplitConstraint);

    // Otherwise, if there is any split in the positional arguments, don't
    // allow the named arguments on the same line as them.
    addRangeConstraint(1, fullySplitValue, rule, Rule.mustSplit);
  }

  @override
  String toString() => 'Pos${super.toString()}';
}

// TODO: This shouldn't be needed any more.
/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * Do not split at all.
/// * Split only before first argument.
/// * Split before all arguments.
class NamedRule extends ArgumentRule {
  @override
  int get numValues => 3;

  /// Creates a new rule for a named argument list.
  ///
  /// [argumentCount] is the number of arguments that will be added to the rule
  /// by later calls to [beforeArgument()].
  ///
  /// If [collectionRule] is given, it is the rule used to split the collection
  /// arguments in the list. It must be provided if [leadingCollections] or
  /// [trailingCollections] is non-zero.
  NamedRule(
      Rule? collectionRule, int leadingCollections, int trailingCollections) {
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
