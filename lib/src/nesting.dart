// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting;

/// A single level of expression nesting.
///
/// When a line is split in the middle of an expression, this tracks the
/// context of where in the expression that split occurs. It ensures that the
/// [LineSplitter] obeys the expression nesting when deciding what column to
/// start lines at when split inside an expression.
///
/// Each instance of this represents a single level of expression nesting. If we
/// split at to chunks with different levels of nesting, the splitter ensures
/// they each get assigned to different columns.
///
/// In addition, each level has an indent. This is the number of spaces it is
/// indented relative to the outer expression. It's almost always
/// [Indent.expression], but cascades are special magic snowflakes and use
/// [Indent.cascade].
class NestingLevel {
  /// The nesting level surrounding this one, or `null` if this is represents
  /// top level code in a block.
  NestingLevel get parent => _parent;
  NestingLevel _parent;

  /// The number of characters that this nesting level is indented relative to
  /// the containing level.
  ///
  /// Normally, this is [Indent.expression], but cascades use [Indent.cascade].
  final int indent;

  /// The number of nesting levels surrounding this one.
  int get depth {
    var result = 0;
    var nesting = this;
    while (nesting != null) {
      result++;
      nesting = nesting.parent;
    }

    return result - 1;
  }

  NestingLevel() : indent = 0;

  NestingLevel._(this._parent, this.indent);

  /// Creates a new deeper level of nesting indented [spaces] more characters
  /// that the outer level.
  NestingLevel nest(int spaces) => new NestingLevel._(this, spaces);

  /// Gets the relative indentation of the nesting level at [depth].
  int indentAtDepth(int depth) {
    // How many levels do we need to walk up to reach [depth]?
    var levels = this.depth - depth;
    assert(levels >= 0);

    var nesting = this;
    for (var i = 0; i < levels; i++) {
      nesting = nesting._parent;
    }

    return nesting.indent;
  }

  /// Discards this level's parent if it is not in [used] (or is not the top
  /// level nesting).
  void removeUnused(Set<NestingLevel> used) {
    // Always keep the top level zero nesting.
    if (_parent == null) return;
    if (_parent._parent == null) return;

    if (used.contains(_parent)) return;

    // Unlink the unused parent from the chain.
    _parent = _parent._parent;

    // TODO(rnystrom): This should walk the entire parent chain looking for
    // unused levels. Stopping after the first can leave some unused levels on
    // the stack. This isn't fatal, but it makes the splitter slower.
    //
    // However, fixing this causes regression 144 to fail. Investigate what's
    // going on there and fix that.
  }

  String toString() => depth.toString();
}

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
class NestingSplitter {
  final NestingSplitter _parent;

  /// The number of characters of indentation for the current nesting.
  int get indent => _indent;
  final int _indent;

  /// The number of surrounding expression nesting levels.
  int get depth => _depth;
  final int _depth;

  NestingSplitter() : this._(null, 0, 0);

  NestingSplitter._(this._parent, this._depth, this._indent);

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
    if (other is! NestingSplitter) return false;

    var self = this;
    while (self != null) {
      if (self._indent != other._indent) return false;
      if (self._depth != other._depth) return false;
      self = self._parent;
      other = other._parent;

      // They should be the same length.
      if ((self == null) != (other == null)) return false;
    }

    return true;
  }

  int get hashCode {
    // TODO(rnystrom): Is it worth iterating through the stack?
    return _indent.hashCode ^ _depth.hashCode;
  }

  /// Takes this nesting stack and produces all of the new nesting stacks that
  /// are possible when followed by [nesting].
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
  /// nesting stack can be modified.
  List<NestingSplitter> update(NestingLevel nesting) {
    if (nesting.depth == _depth) return [this];

    // If the new split is less nested than we currently are, pop and discard
    // the previous nesting levels.
    if (nesting.depth < _depth) {
      // Pop items off the stack until we find the level we are now at.
      var stack = this;
      while (stack != null) {
        if (stack._depth == nesting.depth) return [stack];
        stack = stack._parent;
      }

      // If we got here, the level wasn't found. That means there is no correct
      // stack level to pop to, since the stack skips past our indentation
      // level.
      return [];
    }

    // Going deeper, so try every indentation for every subset of expression
    // nesting levels between the old and new one.
    return _intermediateDepths(_depth, nesting.depth).map((depths) {
      var result = this;

      for (var depth in depths) {
        result = new NestingSplitter._(
            result, depth, result._indent + nesting.indentAtDepth(depth));
      }

      return new NestingSplitter._(
          result, nesting.depth, result._indent + nesting.indent);
    }).toList();
  }

  /// Given [min] and [max], generates all of the subsets of numbers in that
  /// range (exclusive), including the empty set.
  ///
  /// This is used to determine what sets of intermediate nesting levels to
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

        var start =
            previousSubset.isNotEmpty ? previousSubset.last + 1 : min + 1;

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

  /// Shows each indentation level and the nesting depth associated with it.
  ///
  /// For example:
  ///
  ///     |1|3
  ///
  /// Means that the first level of indentation is associated with nesting
  /// level one, and the second level of indentation is associated with nesting
  /// level three.
  String toString() {
    var result = "";

    for (var nesting = this; nesting._depth != 0; nesting = nesting._parent) {
      result = "|${nesting._depth}$result";
    }

    return result;
  }
}
