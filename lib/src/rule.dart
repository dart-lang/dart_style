// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.rule;

import 'chunk.dart';

// TODO(bob): Doc.
/// A constraint that determines the different ways a related set of chunks may
/// be split.
abstract class Rule {
  static int _nextId = 0;

  /// A semi-unique numeric indentifier for the rule.
  ///
  /// This is useful for debugging and also speeds up using the rule in hash
  /// sets. Ids are *semi*-unique because they may wrap around in long running
  /// processes. Since rules are equal based on their identity, this is
  /// innocuous and prevents ids from growing without bound.
  final int id = _nextId = (_nextId + 1) & 0x0fffffff;

  int get numValues;

  // TODO(bob): Eliminate, or let rule decide based on value.
  int get cost => Cost.normal;

  int get hashCode => id.hashCode;

  /// Whether or not this rule should forcibly harden if it ends up containing
  /// a hard split.
  bool get hardenOnHardSplit => true;

  bool isSplit(int value, Chunk chunk);

  String toString() => "$id";
}

/// A rule that always splits a chunk.
class HardSplitRule extends Rule {
  int get numValues => 1;

  /// It's already hardened.
  bool get hardenOnHardSplit => false;

  bool isSplit(int value, Chunk chunk) => true;
}

// TODO(bob): Doc. Better name?
class BlockSplitRule extends Rule {
  /// Two values: 0 is unsplit, 1 is split.
  int get numValues => 2;

  bool isSplit(int value, Chunk chunk) => value == 1;

  String toString() => "${super.toString()}-block";
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

  String toString() => "${super.toString()}-combinators";
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

  int get numValues {
    // If there is just one argument, can either split before it or not.
    if (_arguments.length == 1) return 2;

    // With multiple arguments, can split before any one, none, or all.
    return 2 + _arguments.length;
  }

  void beforeArgument(Chunk chunk) {
    _arguments.add(chunk);
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

  String toString() => "${super.toString()}-args";
}
