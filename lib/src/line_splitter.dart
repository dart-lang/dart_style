// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'dart:math' as math;

import 'chunk.dart';
import 'debug.dart';
import 'line_prefix.dart';

/// The number of spaces in a single level of indentation.
const spacesPerIndent = 2;

/// The number of indentation levels in a single level of expression nesting.
const indentsPerNest = 2;

/// Cost or indent value used to indication no solution could be found.
const invalidSplits = -1;

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
  ///
  /// Returns a two-element list. The first element will be an [int] indicating
  /// where in [buffer] the selection start point should appear if it was
  /// contained in the formatted list of chunks. Otherwise it will be `null`.
  /// Likewise, the second element will be non-`null` if the selection endpoint
  /// is within the list of chunks.
  List<int> apply(StringBuffer buffer) {
    if (debugFormatter) dumpLine(_chunks, _indent);

    var splits = _findBestSplits(new LinePrefix());
    var selection = [null, null];

    // Write each chunk and the split after it.
    buffer.write(" " * (_indent * spacesPerIndent));
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      // If this chunk contains one of the selection markers, tell the writer
      // where it ended up in the final output.
      if (chunk.selectionStart != null) {
        selection[0] = buffer.length + chunk.selectionStart;
      }

      if (chunk.selectionEnd != null) {
        selection[1] = buffer.length + chunk.selectionEnd;
      }

      buffer.write(chunk.text);

      if (i == _chunks.length - 1) {
        // Don't write trailing whitespace after the last chunk.
      } else if (splits.shouldSplitAt(i)) {
        buffer.write(_lineEnding);
        if (chunk.isDouble) buffer.write(_lineEnding);

        var indent = chunk.indent + splits.getNesting(i);
        buffer.write(" " * (indent * spacesPerIndent));

        // Should have a valid set of splits when we get here.
        assert(indent != invalidSplits);
      } else {
        if (chunk.spaceWhenUnsplit) buffer.write(" ");
      }
    }

    return selection;
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// following [prefix].
  SplitSet _findBestSplits(LinePrefix prefix) {
    // Use the memoized result if we have it.
    if (_bestSplits.containsKey(prefix)) return _bestSplits[prefix];

    var indent = prefix.getNextLineIndent(_chunks, _indent);

    var bestSplits;
    var lowestCost;

    // If there are no required splits, consider not splitting any of the soft
    // splits (if there are any) as one possible solution.
    if (!_suffixContainsHardSplits(prefix)) {
      var splits = new SplitSet();
      var cost = _evaluateCost(prefix, indent, splits);

      if (cost != invalidSplits) {
        bestSplits = splits;
        lowestCost = cost;

        // If we fit the whole suffix without any splitting, that's going to be
        // the best solution, so don't bother trying any others.
        if (cost < Cost.overflowChar) {
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

    var length = indent * spacesPerIndent;

    // Don't consider the last chunk, since there's no point in splitting on it.
    for (var i = prefix.length; i < _chunks.length - 1; i++) {
      var split = _chunks[i];

      // We must skip over this chunk if it cannot be split.
      if (_canSplit(prefix, split, skippedParams)) {
        var splitParams = _getSplitParams(prefix, i, split);

        // Find all the params we did *not* split in the prefix that appear in
        // the suffix so we can ensure they aren't split there either.
        var unsplitParams = prefix.unsplitParams.toSet();
        for (var param in skippedParams) {
          if (_suffixContainsParam(i, param)) unsplitParams.add(param);
        }

        // Create new prefixes that go all the way up to the split. There can be
        // multiple solutions here since there are different ways to handle a
        // jump in nesting depth.
        var longerPrefixes = prefix.expand(
          _chunks, unsplitParams, splitParams, i + 1);

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
          if (cost == invalidSplits) continue;

          if (lowestCost == null ||
              cost < lowestCost ||
              (cost == lowestCost && splits.weight > bestSplits.weight)) {
            lowestCost = cost;
            bestSplits = splits;
          }
        }
      }

      // If we go past the end of the page and we've already found a solution
      // that fits, then no other solution that involves overflowing will beat
      // that, so stop.
      length += split.text.length;
      if (split.spaceWhenUnsplit) length++;
      if (length > _pageWidth &&
          lowestCost != null &&
          lowestCost < Cost.overflowChar) {
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

  /// Gets whether the splitter can split [chunk] given [prefix] and
  /// [skippedParams] which come before it.
  ///
  /// This returns `false` if the prefix or skipped params imply that this
  /// chunk's param must also not be applied.
  bool _canSplit(LinePrefix prefix, Chunk chunk,
      Set<SplitParam> skippedParams) {
    // Can always split on a hard split.
    if (chunk.param == null) return true;

    // If we didn't split the param in the prefix, we can't split on the same
    // param in the suffix.
    if (prefix.unsplitParams.contains(chunk.param)) return false;

    // If we already skipped over the chunk's param,
    // have to skip over it on this chunk too.
    if (skippedParams.contains(chunk.param)) return false;

    isParamSkipped(param) {
      if (skippedParams.contains(param)) return false;

      // If any param implied by this one is skipped, then splitting on the
      // starting param would imply it should be split, which violates that,
      // so don't allow the root one to be split.
      for (var implied in param.implies) {
        if (!isParamSkipped(implied)) return false;
      }

      return true;
    }

    return isParamSkipped(chunk.param);
  }

  /// Get the set of params we have forced to split in [prefix] (including
  /// [split] which is also forced to split) that also appear in the suffix.
  ///
  /// We rebuild the set from scratch so that splits that no longer appear in
  /// the shorter suffix are discarded. This helps keep the set small in the
  /// prefix, which maximizes the memoization hits.
  Set<SplitParam> _getSplitParams(LinePrefix prefix, int index, Chunk split) {
    var splitParams = new Set();

    addParam(param) {
      if (_suffixContainsParam(index, param)) splitParams.add(param);

      // Recurse into the params that are implied by this one.
      param.implies.forEach(addParam);
    }

    prefix.splitParams.forEach(addParam);

    // Consider this split too.
    if (split.param != null) addParam(split.param);

    return splitParams;
  }

  /// Gets whether the suffix after [prefix] contains any mandatory splits.
  ///
  /// This includes both hard splits and splits that depend on params that were
  /// set in the prefix.
  bool _suffixContainsHardSplits(LinePrefix prefix) {
    for (var i = prefix.length; i < _chunks.length - 1; i++) {
      if (_chunks[i].isHardSplit || (_chunks[i].isSoftSplit &&
              prefix.splitParams.contains(_chunks[i].param))) {
        return true;
      }
    }

    return false;
  }

  /// Gets whether the suffix of the line after index [split] contains a soft
  /// split using [param].
  bool _suffixContainsParam(int split, SplitParam param) {
    if (param == null) return false;

    for (var i = split + 1; i < _chunks.length; i++) {
      if (_chunks[i].isSoftSplit && _chunks[i].param == param) {
        return true;
      }
    }

    return false;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  int _evaluateCost(LinePrefix prefix, int indent, SplitSet splits) {
    assert(splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    var length = indent * spacesPerIndent;

    var params = new Set();

    var splitIndexes = [];

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * Cost.overflowChar;
      }
    }

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      length += chunk.text.length;

      if (i < _chunks.length - 1) {
        if (splits.shouldSplitAt(i)) {
          endLine();
          splitIndexes.add(i);

          if (chunk.param != null && !params.contains(chunk.param)) {
            // Don't double-count params if multiple splits share the same
            // param.
            // TODO(rnystrom): Is this needed? Can we actually let splits that
            // share a param accumulate cost?
            params.add(chunk.param);
            cost += chunk.param.cost;
          }

          // Start the new line.
          length = (chunk.indent + splits.getNesting(i)) * spacesPerIndent;
        } else {
          if (chunk.spaceWhenUnsplit) length++;
        }
      }
    }

    // See which spans got split. We avoid iterators here for performance.
    for (var i = 0; i < _spans.length; i++) {
      var span = _spans[i];
      for (var j = 0; j < splitIndexes.length; j++) {
        var index = splitIndexes[j];

        // If the split is contained within a span (and is not the tail end of
        // it), the span got split.
        if (index >= span.start && index < span.end) {
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

/// An immutable, persistent set of enabled soft split [Chunk]s.
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

  /// Determines the "weight" of the set.
  ///
  /// This is the sum of the positions where splits occur. Having more splits
  /// increases weight but, more importantly, having a split closer to the end
  /// increases its weight.
  ///
  /// This is used to break a tie when two [SplitSets] have the same cost. When
  /// that occurs, we prefer splits later in the line since that keeps most
  /// code towards the top lines. This occurs frequently in argument lists.
  /// Since every argument split has the same cost, a long argument list can be
  /// split in two a number of equal-cost ways. The weight is used to select
  /// the one that puts the most arguments on the first line(s).
  int get weight {
    var result = 0;
    for (var i = 0; i < _splitNesting.length; i++) {
      if (_splitNesting[i] != null) result += i;
    }

    return result;
  }

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
