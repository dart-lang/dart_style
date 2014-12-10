// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

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

/// Takes a series of [Chunk]s and determines the best way to split them into
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

  /// The list of chunks being split.
  final List<Chunk> _chunks;

  /// The set of spans that wrap around [_chunks].
  final List<Span> _spans;

  /// The leading indentation at the beginning of the first line.
  final int _indent;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, Set<SplitParam>>{};

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
    var nester = new Nester(_indent, new NestingStack());

    // Write each chunk in the line.
    for (var chunk in _chunks) {
      if (chunk.isSplit && chunk.shouldSplit(splits)) {
        buffer.write(_lineEnding);
        if (chunk.isDouble) buffer.write(_lineEnding);

        indent = nester.handleSplit(chunk);

        // Should have a valid set of splits when we get here.
        assert(indent != INVALID_SPLITS);
      } else {
        // Now that we know the line isn't empty, write the leading indentation.
        if (indent != 0) buffer.write(" " * (indent * SPACES_PER_INDENT));
        buffer.write(chunk.text);
        indent = 0;
      }
    }
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// following [prefix].
  Set<SplitParam> _findBestSplits(LinePrefix prefix) {
    var memoized = _bestSplits[prefix];
    if (memoized != null) return memoized;

    var indent = prefix.getNextLineIndent(_chunks, _indent);

    // Find the set of soft splits that occur before going past the page
    // boundary on some line. At least one of them must be split if the end
    // result is going to fit within the page width.
    var length = indent * SPACES_PER_INDENT;
    var firstLineSplitIndices = [];
    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (chunk.isSoftSplit) firstLineSplitIndices.add(i);

      if (chunk.isHardSplit) {
        // Reset the length since we know we'll start a newline. Do not discard
        // any previously found splits. Even though they fit on their own line,
        // they may still need to be split in order to satisfy a later line's
        // need for a certain nesting level.
        length = chunk.indent * SPACES_PER_INDENT;
      } else {
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
      var split = _chunks[i] as SplitChunk;

      var longerPrefix = prefix.expand(_chunks, i + 1);

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
      if (cost == INVALID_SPLITS) continue;

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

    var nester = new Nester(
        prefix.getNextLineIndent(_chunks, _indent, includeNesting: false),
        prefix._nesting);

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      if (chunk.isSplit) {
        if (chunk.shouldSplit(splits)) {
          endLine();
          splitIndexes.add(i);

          // Start the new line.
          indent = nester.handleSplit(chunk);
          if (indent == INVALID_SPLITS) return INVALID_SPLITS;

          length = indent * SPACES_PER_INDENT;
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
  LinePrefix expand(List<Chunk> chunks, int length) {
    var split = chunks[length - 1] as SplitChunk;
    var nesting = _nesting.modify(split);
    if (nesting == null) return null;

    return new LinePrefix._(length, nesting);
  }

  /// Gets the leading indentation of the newline that immediately follows
  /// this prefix.
  ///
  /// Takes into account the indentation of the previous split and any
  /// additional indentation from wrapped nested expressions.
  int getNextLineIndent(List<Chunk> chunks, int indent,
      {bool includeNesting: true}) {
    // TODO(rnystrom): This could be cached at construction time, which may be
    // faster.
    // Get the initial indentation of the line immediately after the prefix,
    // ignoring any extra indentation caused by nested expressions.
    if (length > 0) {
      indent = (chunks[length - 1] as SplitChunk).indent;
    }

    if (includeNesting) indent += _nesting.indent;

    return indent;
  }

  String toString() => "LinePrefix(length: $length, nesting $_nesting)";
}
