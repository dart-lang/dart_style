// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.rule;

import 'chunk.dart';
import 'fast_hash.dart';

/// A constraint that determines the different ways a related set of chunks may
/// be split.
abstract class Rule extends FastHash {
  /// The number of different states this rule can be in.
  ///
  /// Each state determines which set of chunks using this rule are split and
  /// which aren't. Values range from zero to one minus this. Value zero
  /// always means "no chunks are split" and increasing values by convention
  /// mean increasingly undesirable splits.
  int get numValues;

  /// The rule value that forces this rule into its maximally split state.
  ///
  /// By convention, this is the highest of the range of allowed values.
  int get fullySplitValue => numValues - 1;

  int get cost => Cost.normal;

  /// The span of [Chunk]s that were written while this rule was still in
  /// effect.
  ///
  /// This is used to tell which rules should be pre-emptively split if their
  /// contents are too long. This may be a wider range than the set of chunks
  /// enclosed by chunks whose rule is this one. A rule may still be on the
  /// list of open rules for a while after its last chunk is written.
  // TODO(rnystrom): These are only used by preemption which is kind of hacky.
  // Remove this if preemption is redone.
  int start;
  int end;

  /// The other [Rule]s that "surround" this one (and care about that fact).
  ///
  /// In many cases, if a split occurs inside an expression, surrounding rules
  /// also want to split too. For example, a split in the middle of an argument
  /// forces the entire argument list to also split.
  ///
  /// This tracks those relationships. If this rule splits, (sets its value to
  /// [fullySplitValue]) then all of the outer rules will also be set to their
  /// fully split value.
  ///
  /// This contains all direct as well as transitive relationships. If A
  /// contains B which contains C, C's outerRules contains both B and A.
  Iterable<Rule> get outerRules => _outerRules;
  final Set<Rule> _outerRules = new Set<Rule>();

  /// Adds [inner] as an inner rule of this rule if it cares about inner rules.
  ///
  /// When an inner rule splits, it forces any surrounding outer rules to also
  /// split.
  void contain(Rule inner) {
    if (!splitsOnInnerRules) return;
    inner._outerRules.add(this);
  }

  /// Whether this rule cares about rules that it contains.
  ///
  /// If `true` then inner rules will constrain this one and force it to split
  /// when they split. Otherwise, it can split independently of any contained
  /// rules.
  bool get splitsOnInnerRules => true;

  bool isSplit(int value, Chunk chunk);

  /// Given that this rule has [value], determine if [other]'s value should be
  /// constrained.
  ///
  /// Allows relationships between rules like "if I split, then this should
  /// split too". Returns a non-negative value to force [other] to take that
  /// value. Returns -1 to allow [other] to take any non-zero value. Returns
  /// null to not constrain other.
  int constrain(int value, Rule other) {
    // By default, any implied rule will be fully split if this one is fully
    // split.
    if (value == 0) return null;
    if (_outerRules.contains(other)) return other.fullySplitValue;

    return null;
  }

  /// Like [constrain], but in the other direction.
  ///
  /// If [other] has [otherValue], returns the constrained value this rule may
  /// have, or `null` if any value is allowed.
  int reverseConstrain(int otherValue, Rule other) {
    // If [other] did not fully split, then we can't split either if us
    // splitting implies that it should have.
    if (otherValue == other.fullySplitValue) return null;
    if (_outerRules.contains(other)) return 0;

    return null;
  }

  String toString() => "$id";
}

/// A rule that always splits a chunk.
class HardSplitRule extends Rule {
  int get numValues => 1;

  /// It's always going to be applied, so there's no point in penalizing it.
  ///
  /// Also, this avoids doubled counting in literal blocks where there is both
  /// a split in the outer chunk containing the block and the inner hard split
  /// between the elements or statements.
  int get cost => 0;

  /// It's always split anyway.
  bool get splitsOnInnerRules => false;

  bool isSplit(int value, Chunk chunk) => true;

  String toString() => "Hard";
}

/// A basic rule that has two states: unsplit or split.
class SimpleRule extends Rule {
  /// Two values: 0 is unsplit, 1 is split.
  int get numValues => 2;

  final int cost;

  final bool splitsOnInnerRules;

  SimpleRule({int cost, bool splitsOnInnerRules})
      : cost = cost != null ? cost : Cost.normal,
        splitsOnInnerRules = splitsOnInnerRules != null
            ? splitsOnInnerRules
            : true;

  bool isSplit(int value, Chunk chunk) => value == 1;

  String toString() => "Simple${super.toString()}";
}

/// Handles a list of [combinators] following an "import" or "export" directive.
/// Combinators can be split in a few different ways:
///
///     // All on one line:
///     import 'animals.dart' show Ant hide Cat;
///
///     // Wrap before each keyword:
///     import 'animals.dart'
///         show Ant, Baboon
///         hide Cat;
///
///     // Wrap either or both of the name lists:
///     import 'animals.dart'
///         show
///             Ant,
///             Baboon
///         hide Cat;
///
/// These are not allowed:
///
///     // Wrap list but not keyword:
///     import 'animals.dart' show
///             Ant,
///             Baboon
///         hide Cat;
///
///     // Wrap one keyword but not both:
///     import 'animals.dart'
///         show Ant, Baboon hide Cat;
///
/// This ensures that when any wrapping occurs, the keywords are always at
/// the beginning of the line.
class CombinatorRule extends Rule {
  /// The set of chunks before the combinators.
  final Set<Chunk> _combinators = new Set();

  /// A list of sets of chunks prior to each name in a combinator.
  ///
  /// The outer list is a list of combinators (i.e. "hide", "show", etc.). Each
  /// inner set is the set of names for that combinator.
  final List<Set<Chunk>> _names = [];

  int get numValues {
    var count = 2; // No wrapping, or wrap just before each combinator.

    if (_names.length == 2) {
      count += 3; // Wrap first set of names, second, or both.
    } else {
      assert(_names.length == 1);
      count++; // Wrap the names.
    }

    return count;
  }

  /// Adds a new combinator to the list of combinators.
  ///
  /// This must be called before adding any names.
  void addCombinator(Chunk chunk) {
    _combinators.add(chunk);
    _names.add(new Set());
  }

  /// Adds a chunk prior to a name to the current combinator.
  void addName(Chunk chunk) {
    _names.last.add(chunk);
  }

  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case 0:
        // Don't split at all.
        return false;

      case 1:
        // Just split at the combinators.
        return _combinators.contains(chunk);

      case 2:
        // Split at the combinators and the first set of names.
        return _isCombinatorSplit(0, chunk);

      case 3:
        // If there is two combinators, just split at the combinators and the
        // second set of names.
        if (_names.length == 2) {
          // Two sets of combinators, so just split at the combinators and the
          // second set of names.
          return _isCombinatorSplit(1, chunk);
        }

        // Split everything.
        return true;

      case 4:
        return true;
    }

    throw "unreachable";
  }

  /// Returns `true` if [chunk] is for a combinator or a name in the
  /// combinator at index [combinator].
  bool _isCombinatorSplit(int combinator, Chunk chunk) {
    return _combinators.contains(chunk) || _names[combinator].contains(chunk);
  }

  String toString() => "Comb${super.toString()}";
}

abstract class ArgsRule extends Rule {
  /// The rule used to split block arguments in the argument list, if any.
  final Rule _blockRule;

  /// If true, then inner rules that are written will force this rule to split.
  ///
  /// Temporarily disabled while writing block arguments so that they can be
  /// multi-line without forcing the whole argument list to split.
  bool _trackInnerRules = true;

  /// Don't split when an inner block rule splits.
  bool get splitsOnInnerRules => _trackInnerRules;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [_blockRule] is given, it is the rule used to split the block
  /// arguments in the list.
  ArgsRule(this._blockRule);

  /// Called before a block argument is written.
  ///
  /// Disables tracking inner rules while a block argument is being written.
  void beforeBlockArgument() {
    assert(_trackInnerRules == true);
    _trackInnerRules = false;
  }

  /// Called after a block argument is complete.
  ///
  /// Re-enables tracking inner rules after a block argument is complete.
  void afterBlockArgument() {
    assert(_trackInnerRules == false);
    _trackInnerRules = true;
  }
}

/// Base class for a rule for handling positional argument lists.
abstract class PositionalArgsRule extends ArgsRule {
  /// The chunks prior to each positional argument.
  final List<Chunk> _arguments = [];

  /// If there are named arguments following these positional ones, this will
  /// be their rule.
  Rule _namedArgsRule;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [blockRule] is given, it is the rule used to split the block arguments
  /// in the list.
  PositionalArgsRule(Rule blockRule) : super(blockRule);

  /// Remembers [chunk] as containing the split that occurs right before an
  /// argument in the list.
  void beforeArgument(Chunk chunk) {
    _arguments.add(chunk);
  }

  /// Remembers that [rule] is the [NamedArgsRule] immediately following this
  /// positional argument list.
  void setNamedArgsRule(NamedArgsRule rule) {
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
/// not be a block argument.)
class SinglePositionalRule extends PositionalArgsRule {
  int get numValues => 2;

  /// If there is only a single argument, allow it to split internally without
  /// forcing a split before the argument.
  bool get splitsOnInnerRules => false;

  /// Creates a new rule for a positional argument list.
  ///
  /// If [blockRule] is given, it is the rule used to split the block arguments
  /// in the list. If [isSingleArgument] is `true`, then the argument list will
  /// only contain a single argument.
  SinglePositionalRule(Rule blockRule) : super(blockRule);

  bool isSplit(int value, Chunk chunk) => value == 1;

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _blockRule) return null;

    // If we aren't splitting any args, we can split the block.
    if (value == 0) return null;

    // We are splitting before a block, so don't let it split internally.
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
/// Finally, if there are block arguments, there is another value that splits
/// before all of the non-block arguments, but does not split before the block
/// ones, so that they can split internally.
class MultiplePositionalRule extends PositionalArgsRule {
  /// The number of leading block arguments.
  ///
  /// This and [_trailingBlocks] cannot both be positive. If every argument is
  /// a block, this will be [_arguments.length] and [_trailingBlocks] will be 0.
  final int _leadingBlocks;

  /// The number of trailing block arguments.
  ///
  /// This and [_leadingBlocks] cannot both be positive.
  final int _trailingBlocks;

  int get numValues {
    // Can split before any one argument, none, or all.
    var result = 2 + _arguments.length;

    // When there are block arguments, there are two ways we can split on "all"
    // arguments:
    //
    // - Split on just the non-block arguments, and force the block arguments
    //   to split internally.
    // - Split on all of them including the block arguments, and do not allow
    //   the block arguments to split internally.
    if (_leadingBlocks > 0 || _trailingBlocks > 0) result++;

    return result;
  }

  MultiplePositionalRule(
      Rule blockRule, this._leadingBlocks, this._trailingBlocks)
      : super(blockRule);

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

    // Only split before the non-block arguments. Note that we consider this
    // case to correctly prefer this over the latter case because function
    // block arguments always split internally. Preferring this case ensures we
    // avoid:
    //
    //     function( // <-- :(
    //         () {
    //        ...
    //     }),
    //         argument,
    //         ...
    //         argument;
    if (value == _arguments.length + 1) {
      for (var i = 0; i < _leadingBlocks; i++) {
        if (chunk == _arguments[i]) return false;
      }

      for (var i = _arguments.length - _trailingBlocks;
          i < _arguments.length; i++) {
        if (chunk == _arguments[i]) return false;
      }

      return true;
    }

    // Split before all of the arguments, even the block ones.
    return true;
  }

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _blockRule) return null;

    // If we aren't splitting any args, we can split the block.
    if (value == 0) return null;

    // Split only before the first argument.
    if (value == 1) {
      if (_leadingBlocks > 0) {
        // We are splitting before a block, so don't let it split internally.
        return 0;
      } else {
        // The split is outside of the blocks so they can split or not.
        return null;
      }
    }

    // Split before a single argument. If it's in the middle of the block
    // arguments, don't allow them to split.
    if (value <= _arguments.length) {
      var argument = _arguments.length - value + 1;
      if (argument < _leadingBlocks) return 0;
      if (argument >= _arguments.length - _trailingBlocks) return 0;

      return null;
    }

    // Only split before the non-block arguments. This case only comes into
    // play when we do want to split the blocks, so force that here.
    if (value == _arguments.length + 1) return 1;

    // Split before all of the arguments, even the block ones, so don't let
    // them split.
    return 0;
  }
}

/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2: Split before all arguments, including the first.
class NamedArgsRule extends ArgsRule {
  /// The chunk prior to the first named argument.
  Chunk _first;

  int get numValues => 3;

  NamedArgsRule(Rule blockRule) : super(blockRule);

  void beforeArguments(Chunk chunk) {
    assert(_first == null);
    _first = chunk;
  }

  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case 0: return false;
      case 1: return chunk == _first;
      case 2: return true;
    }

    throw "unreachable";
  }

  int constrain(int value, Rule other) {
    var constrained = super.constrain(value, other);
    if (constrained != null) return constrained;

    if (other != _blockRule) return null;

    // If we aren't splitting any args, we can split the block.
    if (value == 0) return null;

    // Split before all of the arguments, even the block ones, so don't let
    // them split.
    return 0;
  }

  String toString() => "Named${super.toString()}";
}
