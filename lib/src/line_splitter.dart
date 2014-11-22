// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'debug.dart';
import 'line.dart';

const _INVALID_SPLITS = -1;

/// Takes a [Line] determines the best way to split it into multiple physical
/// lines of output that fit within the page width (if possible).
///
/// Trying all possible combinations is exponential in the number of splits
/// (which can be large for method calls with a large number of parameters) so
/// a brute force solution won't work. Instead, this uses dynamic programming
/// to avoid recalculating partial results. The basic algorithm works like so:
///
/// Given a suffix of the entire line, we walk over the tokens keeping track
/// of any splits we find until we fill the page width (or run out of line).
/// If we reached the end of the line without crossing the page width, we're
/// fine and the suffix is good as it is.
///
/// If we went over, at least one of those splits must be applied to keep the
/// suffix in bounds. For each of those splits, we split at that point and
/// apply the same algorithm for the remainder of the line. We get the results
/// of all of those, choose the one with the lowest cost, and
/// that's the best solution.
///
/// The fact that this recurses while only removing a small prefix from the
/// line (the chunks before the first split), means this is exponential.
/// Thankfully, though, the best set of splits for a suffix of the line depends
/// only on:
///
///  -   The starting position of the suffix.
///
///  -   The set of expression nesting levels currently being split up to that
///      point.
///
///      For example, consider the following:
///
///          outer(inner(argument1, argument2, argument3));
///
///      If the suffix we are considering is "argument2, ..." then we need to
///      know if we previously split after "outer(", "inner(", or both. The
///      answer determines how much leading indentation "argument2, ..." will
///      have.
///
/// Thus, whenever we calculate an ideal set of splits for some suffix, we
/// memoize it. When later recursive calls descend to that suffix again, we can
/// reuse it.
class LineSplitter {
  /// The string used for newlines.
  final String _lineEnding;

  /// The number of characters allowed in a single line.
  final int _pageWidth;

  /// The (logical) [Line] being split.
  final Line _line;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, Set<SplitParam>>{};

  /// Creates a new splitter that tries to fit lines within [pageWidth].
  LineSplitter(this._lineEnding, this._pageWidth, this._line) {
    assert(_line.chunks.isNotEmpty);
  }

  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// return a single string that may contain one or more newline characters.
  void apply(StringBuffer buffer) {
    if (debugFormatter) _dumpLine();

    _applySplits(_findBestSplits(new LinePrefix()), buffer);
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// following [prefix].
  Set<SplitParam> _findBestSplits(LinePrefix prefix) {
    var memoized = _bestSplits[prefix];
    if (memoized != null) return memoized;

    var indent = prefix.getNextLineIndent(_line);

    // TODO(bob): Clarify "firstLine" in presence of newlines.
    // Find the set of splits that occur before going past the first page
    // boundary. At least one of them must be split if the end result is going
    // to fit within the page width.
    var length = indent * SPACES_PER_INDENT;
    var firstLineSplitIndices = [];
    for (var i = prefix.length; i < _line.chunks.length; i++) {
      var chunk = _line.chunks[i];
      if (chunk is SoftSplitChunk) firstLineSplitIndices.add(i);

      if (chunk is HardSplitChunk) {
        // Reset the length since we know we'll start a newline. Do not discard
        // any previously found splits. Even though they fit on their own line,
        // they may still need to be split in order to satisfy a later line's
        // need for a certain nesting level.
        length = chunk.indent * SPACES_PER_INDENT;
      } else {
        // TODO(bob): Clean up.
        assert(chunk is TextChunk || chunk is SoftSplitChunk || chunk is SpanStartChunk || chunk is SpanEndChunk);
        length += chunk.text.length;
      }

      // Once we reach the end of the page, if we have found any splits, we
      // know we'll need to use one of them. We keep going if we haven't found
      // any splits to handle cases where it's not possible to fit in the page.
      // Even then, we want to get as close as we can, so we keep looking for
      // a split after the page width.
      if (length > _pageWidth && firstLineSplitIndices.isNotEmpty) break;
    }

    // If can't or don't need to split, an empty set is the best result.
    if (length <= _pageWidth || firstLineSplitIndices.isEmpty) return new Set();

    // Find the best solution starting at each possible first split.
    var lowestCost;
    var bestSplits;

    for (var i in firstLineSplitIndices) {
      var split = _line.chunks[i] as SoftSplitChunk;

      var longerPrefix = prefix.expand(_line, i + 1);

      // If we can't split at this chunk without breaking the nesting stack,
      // then ignore this possible solution.
      if (longerPrefix == null) continue;

      var remaining = _findBestSplits(longerPrefix);

      // If there were no valid solutions for this suffix (which usually means
      // the prefix has a nesting stack that doesn't work with later lines),
      // then this prefix can't be used.
      if (remaining == null) continue;

      // TODO(rnystrom): Consider a specialized persistent set type for the
      // param sets. We create new sets by appending a single item to an
      // existing set very frequently, so we can probably optimize for that.

      // Don't mutate the previously cached one.
      var splits = remaining.toSet();
      splits.add(split.param);

      var cost = _evaluateCost(prefix, indent, splits);

      // If the set of splits is invalid (usually meaning an unsplit collection
      // containing a split), then ignore it.
      if (cost == _INVALID_SPLITS) continue;

      if (lowestCost == null || cost < lowestCost) {
        lowestCost = cost;
        bestSplits = splits;
      }
    }

    _bestSplits[prefix] = bestSplits;

    return bestSplits;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  ///
  /// Returns the cost where a higher number is a worse set of splits or
  /// [_INVALID_SPLITS] if the set of splits is completely invalid.
  int _evaluateCost(LinePrefix prefix, int indent, Set<SplitParam> splits) {
    // Rate this set of lines.
    var cost = 0;

    // Apply any param costs.
    for (var param in splits) {
      cost += param.cost;
    }

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var line = 0;
    var length = indent * SPACES_PER_INDENT;

    // Determine which spans got split. Note that the line may not always
    // contain matched start/end pairs. If a hard newline appears in the middle
    // of a span, the line may contain only the beginning or end of a span. In
    // that case, they will effectively do nothing, which is what we want.
    var spanStarts = {};

    // TODO(rnystrom): Instead of determining this after applying the splits,
    // we could store the params as a tree so that every param inside a
    // multisplit is nested under its param. Then a param can only be set if
    // all of its parents are. Investigate if that helps perf.
    // Make sure any unsplit multisplits don't get split across multiple
    // lines. For example, we need to ensure this is not allowed:
    //
    //     [[
    //         element,
    //         element,
    //         element,
    //         element,
    //         element
    //     ]]
    //
    // Here, the inner list is correctly split, but the outer is not even
    // though its contents span multiple lines (because the inner list split).
    // To check this, we'll see if any SplitChunks refer to an unsplit param
    // that was previously seen on a different line.
    var previousParams = new Set();
    var thisLineParams = new Set();

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * SplitCost.OVERFLOW_CHAR;
      }

      // Splitting here, so every param we've seen so far is now on a
      // previous line.
      previousParams.addAll(thisLineParams);
      thisLineParams.clear();

      line++;
    }

    var nester = new Nester(
        prefix.getNextLineIndent(_line, includeNesting: false),
        prefix._nesting);

    for (var i = prefix.length; i < _line.chunks.length; i++) {
      var chunk = _line.chunks[i];

      if (chunk is SpanStartChunk) {
        spanStarts[chunk] = line;
      } else if (chunk is SpanEndChunk) {
        // If the end span is on a different line from the start, pay for it.
        if (spanStarts[chunk.start] != line) cost += chunk.cost;
      } else if (chunk is SplitChunk) {
        // TODO(bob): Cleaner?
        if (chunk is HardSplitChunk || splits.contains(chunk.param)) {
          endLine();

          // Start the new line.
          indent = nester.handleSplit(chunk);
          if (indent == _INVALID_SPLITS) return _INVALID_SPLITS;

          length = indent * SPACES_PER_INDENT;
        } else if (chunk is SoftSplitChunk) {
          // If we've seen the same param on a previous line, the unsplit
          // multisplit got split, so this isn't valid.
          if (previousParams.contains(chunk.param)) return _INVALID_SPLITS;
          thisLineParams.add(chunk.param);

          length += chunk.text.length;
        }
      } else {
        length += chunk.text.length;
      }
    }

    // Finish the last line.
    endLine();

    return cost;
  }

  /// Applies the current set of splits to [line] and breaks it into a series
  /// of individual lines.
  ///
  /// Returns the resulting split lines.
  void _applySplits(Set<SplitParam> splits, StringBuffer buffer) {
    buffer.write(" " * (_line.indent * SPACES_PER_INDENT));

    var nester = new Nester(_line.indent, new NestingStack());

    // Write each chunk in the line.
    for (var chunk in _line.chunks) {
      // TODO(bob): Shared base class for newline and split.
      if (chunk is HardSplitChunk ||
          (chunk is SoftSplitChunk && splits.contains(chunk.param))) {
        buffer.write(_lineEnding);
        buffer.write(" " * (nester.handleSplit(chunk) * SPACES_PER_INDENT));
      } else {
        buffer.write(chunk.text);
      }
    }
  }

  /// Prints [line] to stdout with split chunks made visible.
  ///
  /// This is just for debugging.
  void _dumpLine([LinePrefix prefix, Set<SplitParam> splits]) {
    if (prefix == null) prefix = new LinePrefix();
    if (splits == null) splits = new Set();

    var buffer = new StringBuffer()
        ..write(Color.gray)
        ..write("| " * prefix.getNextLineIndent(_line))
        ..write(Color.none);

    for (var i = prefix.length; i < _line.chunks.length; i++) {
      var chunk = _line.chunks[i];

      if (chunk is SpanStartChunk) {
        buffer.write("${Color.cyan}‹${Color.none}");
      } else if (chunk is SpanEndChunk) {
        buffer.write("${Color.cyan}›(${chunk.cost})${Color.none}");
      } else if (chunk is TextChunk) {
        buffer.write(chunk.text);
      } else if (chunk is SoftSplitChunk) {
        var split = chunk as SoftSplitChunk;
        var color = splits.contains(split.param) ? Color.green : Color.gray;

        buffer.write("$color§${split.param.cost}");
        if (split.nesting != -1) {
          buffer.write(":${split.nesting}");
        }
        buffer.write("${Color.none}");
      } else if (chunk is HardSplitChunk) {
        buffer.write("${Color.magenta}\\n${Color.none}");
      } else {
        // Unexpected chunk type.
        buffer.write("${Color.red}‹$chunk›${Color.none}");
      }
    }

    print(buffer);
  }
}

/// A prefix of a [Line], which in turn can be considered a key to describe
/// the suffix of the remaining line that follows it.
///
/// This is used by the splitter to memoize suffixes whose best splits have
/// previously been calculated. For each unique [LinePrefix], there will be a
/// single set of best splits for the remainder of the line following it.
class LinePrefix {
  /// The number of chunks in the prefix.
  ///
  /// The remainder of the line will the chunks that start at index [length].
  final int length;

  /// The nested expressions in the prefix that are still open at the beginning
  /// of the suffix.
  ///
  /// For example, if the line is `outer(inner(argument))`, and the prefix is
  /// `outer(inner(`, the nesting stack will be two levels deep.
  final NestingStack _nesting;

  /// Creates a new zero-length prefix whose suffix is the entire line.
  LinePrefix() : this._(0, new NestingStack());

  LinePrefix._(this.length, this._nesting) {
    assert(_nesting != null);
  }

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    return length == other.length && _nesting == other._nesting;
  }

  int get hashCode => length.hashCode ^ _nesting.hashCode;

  /// Create a new [LinePrefix] containing the same nesting stack as this one
  /// but expanded to [length].
  ///
  /// [length] is assumed to point to a chunk immediately after a [SplitChunk].
  /// The nesting of that chunk modifies the new prefix's nesting stack.
  ///
  /// Returns `null` if the new split chunk results in an invalid prefix. See
  /// [NestingStack.modify] for details.
  LinePrefix expand(Line line, int length) {
    var split = line.chunks[length - 1] as SoftSplitChunk;
    var nesting = _nesting.modify(split);
    if (nesting == null) return null;

    return new LinePrefix._(length, nesting);
  }

  /// Gets the leading indentation of the newline that immediately follows
  /// this prefix.
  ///
  /// Takes into account the indentation of the previous split and any
  /// additional indentation from wrapped nested expressions.
  int getNextLineIndent(Line line, {bool includeNesting: true}) {
    // TODO(rnystrom): This could be cached at construction time, which may be
    // faster.
    // Get the initial indentation of the line immediately after the prefix,
    // ignoring any extra indentation caused by nested expressions.
    var indent;
    if (length == 0) {
      indent = line.indent;
    } else {
      indent = (line.chunks[length - 1] as SoftSplitChunk).indent;
    }

    if (includeNesting) indent += _nesting.indent;

    return indent;
  }

  String toString() => "LinePrefix(length: $length, nesting $_nesting)";
}

/// Keeps track of indentation caused by wrapped nested expressions within a
/// line.
class Nester {
  /// The current level of statement/definition indentation.
  ///
  /// If a split changes this, that resets the nesting stack, since expression
  /// nesting is specific to the current innermost statement being formatted.
  /// Consider a long method call containing a function body which in turn
  /// contains long method call. The nested stack of the inner call is
  /// unrelated to the outer one.
  int _indent;

  /// The current nesting stack.
  NestingStack _nesting;

  Nester(this._indent, this._nesting);

  /// Updates the indentation state with [split], which should be an enabled
  /// split.
  ///
  /// Returns the number of levels of indentation the next line should have.
  /// Returns [_INVALID_SPLITS] if the split is not allowed for the current
  /// indentation stack.
  int handleSplit(SplitChunk split) {
    if (!split.isInExpression) return split.indent;

    if (split.indent != _indent) {
      _nesting = new NestingStack();
      _indent = split.indent;
    }

    var was = _nesting;
    _nesting = _nesting.modify(split);
    if (_nesting == null) return _INVALID_SPLITS;

    return _indent + _nesting.indent;
  }
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

  /// Modifies the nesting stack by taking into account a split that occurs at
  /// [depth].
  ///
  /// If [depth] is -1, that indicates a split that does not affect nesting --
  /// this is primarily multi-line collections.
  ///
  /// Returns a new nesting stack (which may the same as `this` if no change
  /// was needed). Returns `null` if the split is not allowed for the current
  /// indentation stack. This can happen if a level of nesting is skipped on a
  /// previous line but then needed on a later line. For example:
  ///
  ///     // 40 columns                           |
  ///     callSomeMethod(innerFunction(argument,
  ///         argument, argument), argument, ...
  ///
  /// Here, the second line is indented one level even though it is two levels
  /// of nesting deep (the `(` after `callSomeMethod` and `innerFunction`).
  /// When trying to indent the third line, we are not only one level in, but
  /// there is no level of indentation on the stack that corresponds to that.
  /// When that happens, we just consider this an invalid solution and discard
  /// it.
  NestingStack modify(SplitChunk split) {
    if (!split.isInExpression) return this;

    if (split.nesting == _depth) return this;

    if (split.nesting > _depth) {
      // This expression is deeper than the last split, so add it to the
      // stack.
      return new NestingStack._(this, split.nesting, indent + INDENTS_PER_NEST);
    }

    // Pop items off the stack until we find the level we are now at.
    var stack = this;
    while (stack != null) {
      if (stack._depth == split.nesting) return stack;
      stack = stack._parent;
    }

    // If we got here, the level wasn't found. That means there is no correct
    // stack level to pop to, since the stack skips past our indentation level.
    return null;
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
