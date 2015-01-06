// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting;

import 'chunk.dart';
import 'line_splitter.dart';

/// Maintains a stack of nested expressions that have currently been split.
///
/// A single statement may have multiple different levels of indentation based
/// on the expression nesting level at the point where the line is broken. For
/// example:
///
///     someFunction(argument, argument,
///         innerFunction(argument,
///             innermost), argument);
///
/// This means that when splitting a line, we need to keep track of the nesting
/// level of the previous line(s) to determine how far the next line must be
/// indented.
///
/// This class is a persistent collection. Each instance is immutable and
/// methods to modify it return a new collection.
class NestingStack {
  /// The number of visible indentation levels for the current nesting.
  ///
  /// This may be less than [_depth] since split lines can skip multiple
  /// nesting depths.
  final int indent;

  final NestingStack _parent;

  /// The number of surrounding expression nesting levels.
  final int _depth;

  NestingStack() : this._(null, -1, 0);

  NestingStack._(this._parent, this._depth, this.indent);

  /// LinePrefixes implement their own value equality to ensure that two
  /// prefixes with the same nesting stack are considered equal even if the
  /// nesting occurred from different splits.
  ///
  /// For example, consider these two prefixes with `^` marking where splits
  /// have been applied:
  ///
  ///     fn( first, second, ...
  ///        ^
  ///     fn( first, second, ...
  ///               ^
  ///
  /// These are equivalent from the view of the suffix because they have the
  /// same nesting stack, even though the nesting came from different tokens.
  /// This lets us reuse memoized suffixes more frequently when solving.
  bool operator ==(other) {
    if (other is! NestingStack) return false;

    var self = this;
    while (self != null) {
      if (self._depth != other._depth) return false;
      self = self._parent;
      other = other._parent;

      // They should be the same length.
      if ((self == null) != (other == null)) return false;
    }

    return true;
  }

  int get hashCode {
    // TODO(rnystrom): Is it worth iterating throught the stack?
    return indent.hashCode ^ _depth.hashCode;
  }

  /// Takes this nesting stack and produces all of the new nesting stacks that
  /// are possible when followed by the nesting level of [split].
  ///
  /// This may produce multiple solutions because a non-incremental jump in
  /// nesting depth can be sliced up multiple ways. Let's say the prefix is:
  ///
  ///     first(second(third(...
  ///
  /// The current nesting stack is empty (since we're on the first line). How
  /// do we modify it by taking into account the split after `third(`? The
  /// simple answer is to just increase the indentation by one level:
  ///
  ///     first(second(third(
  ///         argumentToThird)));
  ///
  /// This is correct in most cases, but not all. Consider:
  ///
  ///     first(second(third(
  ///         argumentToThird),
  ///     argumentToSecond));
  ///
  /// Oops! There's no place for `argumentToSecond` to go. To handle that, the
  /// second line needs to be indented one more level to make room for the later
  /// line:
  ///
  ///     first(second(third(
  ///             argumentToThird),
  ///         argumentToSecond));
  ///
  /// It's even possible we may need to do:
  ///
  ///     first(second(third(
  ///                 argumentToThird),
  ///             argumentToSecond),
  ///         argumentToFirst);
  ///
  /// To accommodate those, this returns the list of all possible ways the
  /// nesting stack can be modified. It generates the in order of best to worst
  /// so that the line splitter can stop as soon as it finds a working solution.
  /// "Best" here means it tries fewer levels of indentation first.
  List<NestingStack> applySplit(Chunk split) {
    assert(split.isInExpression);

    if (split.nesting == _depth) return [this];

    // If the new split is less nested than we currently are, pop and discard
    // the previous nesting levels.
    if (split.nesting < _depth) {
      // Pop items off the stack until we find the level we are now at.
      var stack = this;
      while (stack != null) {
        if (stack._depth == split.nesting) return [stack];
        stack = stack._parent;
      }

      // If we got here, the level wasn't found. That means there is no correct
      // stack level to pop to, since the stack skips past our indentation
      // level.
      return [];
    }

    // TODO(rnystrom): This eagerly generates all of the nesting stacks even
    // though LineSplitter._findBestSplits() will early out of looping over
    // them. Optimize by generating these only as needed.

    // Going deeper, so try every indentating for every subset of expression
    // nesting levels between the old and new one.
    return _intermediateDepths(_depth, split.nesting).map((depths) {
      var result = this;

      for (var depth in depths) {
        result = new NestingStack._(
            result, depth, result.indent + indentsPerNest);
      }

      return new NestingStack._(
          result, split.nesting, result.indent + indentsPerNest);
    }).toList();
  }

  /// Given [min] and [max], generates all of the subsets of numbers in that
  /// range (exclusive), including the empty set.
  ///
  /// This is used for determine what sets of intermediate nesting levels to
  /// consider when jumping from a shallow nesting level to a much deeper one.
  /// Subsets are generated in order of increasing length. For example, `(2, 6)`
  /// yields:
  ///
  ///     []
  ///     [3] [4] [5]
  ///     [3, 4] [3, 5] [4, 5]
  ///     [3, 4, 5]
  ///
  /// This ensures the splitter prefers solutions that use the least
  /// indentation.
  List<List<int>> _intermediateDepths(int min, int max) {
    assert(min < max);

    var subsets = [[]];

    var lastLengthStart = 0;
    var lastLengthEnd = subsets.length;

    // Generate subsets in order of increasing length.
    for (var length = 1; length <= max - min + 1; length++) {
      // Start with each subset containing one fewer element.
      for (var i = lastLengthStart; i < lastLengthEnd; i++) {
        var previousSubset = subsets[i];

        var start = previousSubset.isNotEmpty ? previousSubset.last + 1 : min + 1;

        // Then for each value in the remainer, make a new subset that is the
        // union of the shorter subset and that value.
        for (var j = start; j < max; j++) {
          var subset = previousSubset.toList()..add(j);
          subsets.add(subset);
        }
      }

      // Move on to the next length range.
      lastLengthStart = lastLengthEnd;
      lastLengthEnd = subsets.length;
    }

    return subsets;
  }

  String toString() {
    var nesting = this;
    var levels = [];
    while (nesting != null) {
      levels.add("${nesting._depth}:${nesting.indent}");
      nesting = nesting._parent;
    }

    return levels.join(" ");
  }
}
