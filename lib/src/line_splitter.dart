// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'dart:math' as math;

import 'chunk.dart';
import 'cost.dart';
import 'debug.dart';
import 'nesting.dart';

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

/// The number of indentation levels in a single level of expression nesting.
const INDENTS_PER_NEST = 2;

/// Cost or indent value used to indication no solution could be found.
const INVALID_SPLITS = -1;

// TODO(rnystrom): This needs to be updated to take into account how it works
// now.
/// Takes a series of [Chunk]s and determines the best way to split them into
/// lines of output that fit within the page width (if possible).
///
/// Trying all possible combinations is exponential in the number of
/// [SplitParam]s and expression nesting levels both of which can be quite large
/// with things like long method chains containing function literals, lots of
/// named parameters, etc. To tame that, this uses dynamic programming. The
/// basic process is:
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

  /// The list of chunks being split.
  final List<Chunk> _chunks;

  /// The set of spans that wrap around [_chunks].
  final List<Span> _spans;

  /// The leading indentation at the beginning of the first line.
  final int _indent;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, SplitSet>{};

  /// Creates a new splitter that tries to fit a series of chunks within a
  /// given page width.
  LineSplitter(this._lineEnding, this._pageWidth, this._chunks, this._spans,
      this._indent) {
    assert(_chunks.isNotEmpty);
  }

  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// return a single string that may contain one or more newline characters.
  void apply(StringBuffer buffer) {
    if (debugFormatter) dumpLine(_chunks, _indent);

    var splits = _findBestSplits(new LinePrefix());

    var indent = _indent;

    // Write each chunk in the line.
    for (var i = 0; i < _chunks.length; i++) {
      if (splits.shouldSplitAt(i)) {
        var split = _chunks[i] as SplitChunk;
        buffer.write(_lineEnding);
        if (split.isDouble) buffer.write(_lineEnding);

        indent = split.indent + splits.getNesting(i);

        // Should have a valid set of splits when we get here.
        assert(indent != INVALID_SPLITS);
      } else {
        // Now that we know the line isn't empty, write the leading indentation.
        if (indent != 0) buffer.write(" " * (indent * SPACES_PER_INDENT));
        buffer.write(_chunks[i].text);
        indent = 0;
      }
    }
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// following [prefix].
  SplitSet _findBestSplits(LinePrefix prefix) {
    // Use the memoized result if we have it.
    if (_bestSplits.containsKey(prefix)) return _bestSplits[prefix];

    var indent = prefix.getNextLineIndent(_chunks, _indent);

    var bestSplits;
    var lowestCost;

    var hasHard = false;
    for (var i = prefix.length; i < _chunks.length; i++) {
      if (_chunks[i].isHardSplit || (_chunks[i].isSoftSplit &&
              prefix.splitParams.contains((_chunks[i] as SplitChunk).param))) {
        hasHard = true;
        break;
      }
    }

    // If there are no required splits, consider not splitting any of the soft
    // splits (if there are any) as one possible solution.
    if (!hasHard) {
      var splits = new SplitSet();
      var cost = _evaluateCost(prefix, indent, splits);

      if (cost != INVALID_SPLITS) {
        bestSplits = splits;
        lowestCost = cost;

        // If we fit the whole suffix without any splitting, that's going to be
        // the best solution, so don't bother trying any others.
        if (cost < Cost.OVERFLOW_CHAR) {
          _bestSplits[prefix] = bestSplits;
          return bestSplits;
        }
      }
    }

    // For each split in the suffix, calculate the best cost where that is the
    // first split applied. This recurses so that for each split, we consider
    // all of the possible sets of splits *after* it and determine the best
    // cost subset out of all of those.
    var skippedParams = new Set();

    var length = indent * SPACES_PER_INDENT;

    for (var i = prefix.length; i < _chunks.length; i++) {
      length += _chunks[i].text.length;

      if (!_chunks[i].isSplit) continue;

      var split = _chunks[i] as SplitChunk;

      // If we didn't split the param in the prefix, we can't split on the same
      // param in the suffix.
      if (split.isSoftSplit &&
          prefix.unsplitParams.contains(split.param)) {
        continue;
      }

      // If we already skipped over this param, have to skip over it here too.
      if (split.isSoftSplit && skippedParams.contains(split.param)) continue;

      suffixContainsParam(param) {
        if (param == null) return false;

        for (var j = i + 1; j < _chunks.length; j++) {
          if (_chunks[j].isSoftSplit &&
              (_chunks[j] as SplitChunk).param == param) {
            return true;
          }
        }

        return false;
      }

      // If the split's param is used in the suffix, we need to ensure that the
      // suffix knows that.
      var addedSplitParam =
          suffixContainsParam(split.param) ? split.param : null;

      // Find all the params we did *not* split in the prefix that appear in
      // the suffix so we can ensure they aren't split there either.
      var unsplitParams = new Set();
      for (var param in skippedParams) {
        if (suffixContainsParam(param)) unsplitParams.add(param);
      }

      // Create new prefixes that go all the way up to the split. There can be
      // multiple solutions here since there are different ways to handle a
      // jump in nesting depth.
      var longerPrefixes = prefix.expand(
          _chunks, unsplitParams, addedSplitParam, i + 1);

      for (var longerPrefix in longerPrefixes) {
        // Given the nesting stack for this split, see what we can do with the
        // rest of the line.
        var remaining = _findBestSplits(longerPrefix);

        // If it wasn't possible to split the suffix given this nesting stack,
        // skip it.
        if (remaining == null) continue;

        var splits = remaining.add(i, longerPrefix.nestingIndent);
        var cost = _evaluateCost(prefix, indent, splits);

        // If the suffix is invalid (because of a mis-matching multisplit),
        // skip it.
        if (cost == INVALID_SPLITS) continue;

        if (lowestCost == null || cost < lowestCost) {
          lowestCost = cost;
          bestSplits = splits;

          // If we found a set of expression nesting levels that reaches a good
          // solution, we can stop. Since we try them in increasingly complex
          // order, the first non-overflowing solution will be the best.
          if (lowestCost < Cost.OVERFLOW_CHAR) break;
        }
      }

      // If we go past the end of the page and we've already found a solution
      // that fits, then no other solution that involves overflowing will beat
      // that, so stop.
      if (length > _pageWidth &&
          lowestCost != null &&
          lowestCost < Cost.OVERFLOW_CHAR) {
        break;
      }

      // If we can't leave this split unsplit (because it's hard or has a
      // param that the prefix already forced to split), then stop.
      if (split.isHardSplit) break;
      if (prefix.splitParams.contains(split.param)) break;

      skippedParams.add(split.param);
    }

    _bestSplits[prefix] = bestSplits;

    return bestSplits;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  ///
  /// Returns the cost where a higher number is a worse set of splits or
  /// [_INVALID_SPLITS] if the set of splits is completely invalid.
  int _evaluateCost(LinePrefix prefix, int indent, SplitSet splits) {
    assert(splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    var line = 0;
    var length = indent * SPACES_PER_INDENT;

    var params = new Set();

    // TODO(rnystrom): Instead of determining this after applying the splits,
    // we could store the params as a tree so that every param inside a
    // multisplit is nested under its param. Then a param can only be set if
    // all of its parents are. Updating and reading from these sets is a major
    // perf bottleneck right now.
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

    var splitIndexes = [];

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * Cost.OVERFLOW_CHAR;
      }

      // Splitting here, so every param we've seen so far is now on a
      // previous line.
      previousParams.addAll(thisLineParams);
      thisLineParams.clear();

      line++;
    }

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      if (chunk.isSplit) {
        var split = chunk as SplitChunk;

        if (splits.shouldSplitAt(i)) {
          endLine();
          splitIndexes.add(i);

          if (split.param != null && !params.contains(split.param)) {
            // Don't double-count params if multiple splits share the same
            // param.
            // TODO(rnystrom): Is this needed? Can we actually let splits that
            // share a param accumulate cost?
            params.add(split.param);
            cost += split.param.cost;
          }

          // Start the new line.
          length = (split.indent + splits.getNesting(i)) * SPACES_PER_INDENT;
        } else if (chunk.isSoftSplit) {
          // If we've seen the same param on a previous line, the unsplit
          // multisplit got split, so this isn't valid.
          if (previousParams.contains(chunk.param)) return INVALID_SPLITS;
          thisLineParams.add(chunk.param);

          length += chunk.text.length;
        }
      } else {
        length += chunk.text.length;
      }
    }

    // See which spans got split. We avoid iterators here for performance.
    for (var i = 0; i < _spans.length; i++) {
      var span = _spans[i];

      for (var j = 0; j < splitIndexes.length; j++) {
        var index = splitIndexes[j];
        if (index >= span.start && index <= span.end) {
          cost += span.cost;
          break;
        }
      }
    }

    // Finish the last line.
    endLine();

    return cost;
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

  /// The [SplitParam]s for params that appear both in the prefix and suffix
  /// and have not been set.
  ///
  /// This is used to ensure that we honor the decisions already made in the
  /// prefix when processing the suffix. It only includes params that appear in
  /// the suffix to avoid storing information about irrelevant params. This is
  /// critical to ensure we keep prefixes simple to maximize the reuse we get
  /// from the memoization table.
  ///
  /// This does *not* include params that appear only in the suffix. In other
  /// words, it only includes params that have deliberately been chosen to not
  /// be set, not params we simply haven't considered yet.
  final Set<SplitParam> unsplitParams;

  /// The [SplitParam]s for params that appear both in the prefix and suffix
  /// and have been set.
  ///
  /// This is used to ensure that we honor the decisions already made in the
  /// prefix when processing the suffix. It only includes params that appear in
  /// the suffix to avoid storing information about irrelevant params. This is
  /// critical to ensure we keep prefixes simple to maximize the reuse we get
  /// from the memoization table.
  final Set<SplitParam> splitParams;

  /// The nested expressions in the prefix that are still open at the beginning
  /// of the suffix.
  ///
  /// For example, if the line is `outer(inner(argument))`, and the prefix is
  /// `outer(inner(`, the nesting stack will be two levels deep.
  final NestingStack _nesting;

  /// The depth of indentation caused expression nesting.
  int get nestingIndent => _nesting.indent;

  /// Creates a new zero-length prefix whose suffix is the entire line.
  LinePrefix([int length = 0])
      : this._(length, new Set(), new Set(), new NestingStack());

  LinePrefix._(this.length, this.unsplitParams, this.splitParams,
      this._nesting) {
    assert(_nesting != null);
  }

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_nesting != other._nesting) return false;

    if (unsplitParams.length != other.unsplitParams.length) {
      return false;
    }

    if (splitParams.length != other.splitParams.length) {
      return false;
    }

    for (var param in unsplitParams) {
      if (!other.unsplitParams.contains(param)) return false;
    }

    for (var param in splitParams) {
      if (!other.splitParams.contains(param)) return false;
    }

    return true;
  }

  int get hashCode => length.hashCode ^ _nesting.hashCode;

  /// Create zero or more new [LinePrefix]es starting from the same nesting
  /// stack as this one but expanded to [length].
  ///
  /// [length] is assumed to point to a chunk immediately after a [SplitChunk].
  /// The nesting of that chunk modifies the new prefix's nesting stack.
  ///
  /// [unsplitParams] is the set of [SplitParam]s not in this prefix but in the
  /// new prefix that the splitter decided to *not* split. [splitParam] is the
  /// [SplitParam] in the new prefix that has been chosen to be split. It will
  /// be `null` if that param does not appear in the suffix of the line.
  ///
  /// Returns an empty list if the new split chunk results in an invalid prefix.
  /// See [NestingStack.applySplit] for details.
  Iterable<LinePrefix> expand(List<Chunk> chunks, Set<SplitParam> unsplitParams,
      SplitParam splitParam, int length) {
    var split = chunks[length - 1] as SplitChunk;

    var newUnsplitMultiParams = unsplitParams;
    if (unsplitParams.isNotEmpty) {
      newUnsplitMultiParams = unsplitParams.toSet();
      newUnsplitMultiParams.addAll(unsplitParams);
    }

    var newSplitMultiParams = splitParams;
    if (splitParam != null) {
      newSplitMultiParams = splitParams.toSet();
      newSplitMultiParams.add(splitParam);
    }

    if (!split.isInExpression) {
      return [
        new LinePrefix._(length, newUnsplitMultiParams, newSplitMultiParams,
            new NestingStack())
      ];
    }

    return _nesting.applySplit(split).map((nesting) =>
        new LinePrefix._(
            length, newUnsplitMultiParams, newSplitMultiParams, nesting));
  }

  /// Gets the leading indentation of the newline that immediately follows
  /// this prefix.
  ///
  /// Takes into account the indentation of the previous split and any
  /// additional indentation from wrapped nested expressions.
  int getNextLineIndent(List<Chunk> chunks, int indent) {
    // TODO(rnystrom): This could be cached at construction time, which may be
    // faster.
    // Get the initial indentation of the line immediately after the prefix,
    // ignoring any extra indentation caused by nested expressions.
    if (length > 0) {
      indent = (chunks[length - 1] as SplitChunk).indent;
    }

    return indent + _nesting.indent;
  }

  String toString() =>
      "LinePrefix(length $length, nesting $_nesting, "
      "unsplit $unsplitParams, split $splitParams)";
}

/// An immutable, persistent set of enabled [SplitChunk]s.
///
/// For each chunk, this tracks if it has been split and, if so, what the
/// chosen level of expression nesting is for the following line.
///
/// Internally, this uses a sparse parallel list where each element corresponds
/// to the nesting level of the chunk at that index in the chunk list, or `null`
/// if there is no active split there. This had about a 10% perf improvement
/// over using a [Set] of splits or a persistent linked list of split
/// index/nesting pairs.
class SplitSet {
  List<int> _splitNesting;

  /// Creates a new empty split set.
  SplitSet() : this._(const []);

  SplitSet._(this._splitNesting);

  /// Returns a new [SplitSet] containing the union of this one and the split
  /// at [splitIndex] with [nestingIndent].
  SplitSet add(int splitIndex, int nestingIndent) {
    var newNesting = new List(math.max(splitIndex + 1, _splitNesting.length));
    newNesting.setAll(0, _splitNesting);
    newNesting[splitIndex] = nestingIndent;

    return new SplitSet._(newNesting);
  }

  /// Returns `true` if the chunk at [splitIndex] should be split.
  bool shouldSplitAt(int splitIndex) =>
      splitIndex < _splitNesting.length && _splitNesting[splitIndex] != null;

  /// Gets the nesting level of the split chunk at [splitIndex].
  int getNesting(int splitIndex) => _splitNesting[splitIndex];

  String toString() {
    var result = [];
    for (var i = 0; i < _splitNesting.length; i++) {
      if (_splitNesting[i] != null) {
        result.add("$i:${_splitNesting[i]}");
      }
    }

    return result.join(" ");
  }
}
