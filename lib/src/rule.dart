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
  // TODO(bob): This is only being used by preemption which is kind of hacky.
  // Get rid of this?
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
    if (value != fullySplitValue) return null;
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

/// Splitting rule for a list of position arguments or parameters. Given an
/// argument list with, say, 5 arguments, its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2...5: Split between one pair of arguments working back to front.
/// * 6: Split before all arguments, including the first.
class PositionalArgsRule extends Rule {
  /// The chunks prior to each positional argument.
  final List<Chunk> _arguments = [];

  /// If there are named arguments following these positional ones, this will
  /// be their rule.
  Rule _namedArgsRule;

  int get numValues {
    // If there is just one argument, can either split before it or not.
    if (_arguments.length == 1) return 2;

    // With multiple arguments, can split before any one, none, or all.
    return 2 + _arguments.length;
  }

  /// If there is only a single argument, allow it to split internally without
  /// forcing a split before the argument.
  final bool splitsOnInnerRules;

  PositionalArgsRule({bool isSingleArgument})
      : splitsOnInnerRules = !isSingleArgument;

  void beforeArgument(Chunk chunk) {
    _arguments.add(chunk);
  }

  void setNamedArgsRule(NamedArgsRule rule) {
    _namedArgsRule = rule;
  }

  bool isSplit(int value, Chunk chunk) {
    // Don't split at all.
    if (value == 0) return false;

    // If there is only one argument, split before it.
    if (_arguments.length == 1) return true;

    // Split only before the first argument. Keep the entire argument list
    // together on the next line.
    if (value == 1) return chunk == _arguments.first;

    // Put each argument on its own line.
    if (value == numValues - 1) return true;

    // Otherwise, split between exactly one pair of arguments. Try later
    // arguments before earlier ones to try to keep as much on the first line
    // as possible.
    var argument = numValues - value - 1;
    return chunk == _arguments[argument];
  }

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

  String toString() => "Pos${super.toString()}";
}

/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2: Split before all arguments, including the first.
class NamedArgsRule extends Rule {
  /// The chunk prior to the first named argument.
  Chunk _first;

  int get numValues => 3;

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

  String toString() => "Named${super.toString()}";
}
