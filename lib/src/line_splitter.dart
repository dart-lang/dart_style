// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'line.dart';

/// Takes a single [Line] which may contain multiple [SplitParam]s and
/// [SplitRule]s and determines the best way to split it into multiple physical
/// lines of output that fit within the page width (if possible).
///
/// Finding the best solution to this problem is exponential in the number of
/// splits (which can be large for method calls with a large number of
/// parameters) so a naïve brute force solution won't work here. We also can't
/// do something like path-finding since we don't know what the best solution
/// will be ahead of time.
///
/// Instead, this uses dynamic programming to avoid recalculating partial
/// results. The basic algorithm works like so:
///
/// Given a suffix of the entire line, we walk over the tokens keeping track
/// of any splits we find until we fill the page width (or run out of line).
/// If we reached the end of the line without crossing the page width, we're
/// fine and the line is good as it is.
///
/// If we went over, at least one of those splits must be applied to keep the
/// remainder of the line in bounds. For each of those splits, we split at
/// that point and apply the same algorithm for the remainder of the line. We
/// get the results of all of those, choose the one with the lowest cost, and
/// that's the best solution.
///
/// The fact that this recurses while only removing a small prefix from the
/// line (the chunks before the first split), this is exponential. Thankfully,
/// though, the best set of splits for a suffix of the line are independent of
/// anything that comes before it. So, whenever we calculate an ideal set of
/// splits for some suffix, we memoize it. When later recursive calls descend
/// to that suffix again, we can reuse it.
class LineSplitter {
  /// The number of characters allowed in a single line.
  final int _pageWidth;

  /// The (logical) [Line] being split.
  final Line _line;

  /// Memoization table for the best set of splits for the remainder of the
  /// line starting at a given chunk index.
  ///
  /// Keys are chunk indices, and values are the best set of split params to
  /// split the line starting at that chunk. The key will always be a chunk
  /// immediately following a split chunk, and the memoized set assumes the
  /// indentation of that previous split.
  final _bestSplits = <int, Set<SplitParam>>{};

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LineSplitter(this._pageWidth, this._line);

  // TODO(rnystrom): Pass StringBuffer into this?
  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// return a single string that may contain one or more newline characters.
  String apply() {
    if (!_line.hasSplits || _line.unsplitLength <= _pageWidth) {
      // No splitting needed or possible.
      return _printUnsplit();
    }

    var lines = _applySplits(_findBestSplits(0, _line.indent));
    if (lines == null) {
      // Could not split it.
      return _printUnsplit();
    }

    // TODO(rnystrom): Use configured line separator.
    return lines.join("\n");
  }

  /// Prints [line] without any splitting.
  String _printUnsplit() {
    var buffer = new StringBuffer();
    buffer.write(" " * (_line.indent * SPACES_PER_INDENT));
    buffer.writeAll(_line.chunks);

    return buffer.toString();
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// starting at [startChunk] with initial indentation [indent].
  Set<SplitParam> _findBestSplits(int startChunk, int indent) {
    var memoized = _bestSplits[startChunk];
    if (memoized != null) return memoized;

    // Find the set of splits within the first line. At least one of them must
    // be split if the end result is going to fit within the page width.
    var length = indent * SPACES_PER_INDENT;
    var firstLineSplitIndices = [];
    for (var i = startChunk; i < _line.chunks.length; i++) {
      var chunk = _line.chunks[i];
      if (chunk is SplitChunk) firstLineSplitIndices.add(i);

      length += chunk.text.length;

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
      var split = _line.chunks[i] as SplitChunk;
      var remaining = _findBestSplits(i + 1, split.indent);

      // TODO(rnystrom): Consider a specialized persistent set type for the
      // param sets. We create new sets by appending a single item to an
      // existing set very frequently, so we can probably optimize for that.

      // Don't mutate the previously cached one.
      var splits = remaining.toSet();
      splits.add(split.param);

      // TODO(rnystrom): Instead of recalculating the cost from scratch,
      // consider memoizing these too.
      var cost = _evaluateCost(startChunk, indent, splits);

      // TODO(rnystrom): We can remove this check if we have a better way of
      // checking for splits inside multisplits.
      // If the set of splits is invalid (usually meaning an unsplit collection
      // containing a split, then ignore it.
      if (cost == null) continue;

      if (lowestCost == null || cost < lowestCost) {
        lowestCost = cost;
        bestSplits = splits;
      }
    }

    _bestSplits[startChunk] = bestSplits;

    return bestSplits;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  ///
  /// Returns the cost where a higher number is a worse set of splits or `null`
  /// if the set of splits is completely invalid.
  int _evaluateCost(int startChunk, int indent, Set<SplitParam> splits) {
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

    for (var i = startChunk; i < _line.chunks.length; i++) {
      var chunk = _line.chunks[i];

      if (chunk is SpanStartChunk) {
        spanStarts[chunk] = line;
      } else if (chunk is SpanEndChunk) {
        // If the end span is on a different line from the start, pay for it.
        if (spanStarts[chunk.start] != line) cost += chunk.cost;
      } else if (chunk is SplitChunk) {
        if (splits.contains(chunk.param)) {
          endLine();

          // Start the new line.
          length = chunk.indent * SPACES_PER_INDENT;
        } else {
          // If we've seen the same param on a previous line, the unsplit
          // multisplit got split, so this isn't valid.
          if (previousParams.contains(chunk.param)) return null;
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
  List<String> _applySplits(Set<SplitParam> splits) {
    var lines = [];
    var buffer = new StringBuffer();
    buffer.write(" " * (_line.indent * SPACES_PER_INDENT));

    // Write each chunk in the line.
    for (var chunk in _line.chunks) {
      if (chunk is SplitChunk && splits.contains(chunk.param)) {
        lines.add(buffer.toString());
        buffer.clear();
        buffer.write(" " * (chunk.indent * SPACES_PER_INDENT));
      } else {
        buffer.write(chunk.text);
      }
    }

    // Finish the last line.
    if (!buffer.isEmpty) lines.add(buffer.toString());

    return lines;
  }

  /// Prints [line] to stdout with split chunks made visible.
  ///
  /// This is just for debugging.
  void _dumpLine(Line line, Set<SplitParam> splits) {
    var cyan = '\u001b[36m';
    var gray = '\u001b[1;30m';
    var green = '\u001b[32m';
    var red = '\u001b[31m';
    var magenta = '\u001b[35m';
    var none = '\u001b[0m';

    var buffer = new StringBuffer()
        ..write(gray)
        ..write("| " * line.indent)
        ..write(none);

    for (var chunk in line.chunks) {
      if (chunk is SpanStartChunk) {
        buffer.write("$cyan‹$none");
      } else if (chunk is SpanEndChunk) {
        buffer.write("$cyan›(${chunk.cost})$none");
      } else if (chunk is TextChunk) {
        buffer.write(chunk);
      } else {
        var split = chunk as SplitChunk;
        var color = splits.contains(split.param) ? green : gray;

        buffer
            ..write("$color‹")
            ..write(split.param.cost)
            ..write("›$none");
      }
    }

    print(buffer);
  }
}
