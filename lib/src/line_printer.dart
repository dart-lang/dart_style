// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'line.dart';

// TODO(rnystrom): Rename and clean up.
/// Takes a single [Line] which may contain multiple [SplitParam]s and
/// [SplitRule]s and determines the best way to split it into multiple physical
/// lines of output that fit within the page width (if possible).
class LineSplitter {
  // TODO(rnystrom): Remove or expose in a more coherent way.
  static bool debug = false;

  final int _pageWidth;

  final Line _line;

  // TODO(rnystrom): Document.
  final _params = new List<SplitParam>();

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LineSplitter(this._pageWidth, this._line);

  // TODO(rnystrom): Pass StringBuffer into this?
  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// return a single string that may contain one or more newline characters.
  String apply() {
    if (debug) _dumpLine(_line);

    if (!_line.hasSplits || _line.unsplitLength <= _pageWidth) {
      // No splitting needed or possible.
      return _printUnsplit();
    }

    // See which parameters we can toggle for the line.
    var params = new Set<SplitParam>();
    for (var chunk in _line.chunks) {
      if (chunk is! SplitChunk) continue;
      params.add(chunk.param);
    }

    _params.addAll(params);

    var lines = _chooseSplits();

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

  /// Chooses which set of splits to apply to get the most appealing result.
  ///
  /// Tries every possible combination of splits and returns the best set. This
  /// is fast when the total number of combinations is relatively slow but gets
  /// slow quickly (it's exponential in the number of params).
  List<String> _chooseSplits() {
    var lowestCost;

    // The set of lines whose splits have the lowest total cost so far.
    var best;

    // Try every combination of params being enabled or disabled.
    for (var i = 0; i < (1 << _params.length); i++) {
      // Set a combination of params.
      for (var j = 0; j < _params.length; j++) {
        _params[j].isSplit = i & (1 << j) != 0;
      }

      var cost = _evaluateCost();
      if (cost == null) continue;

      if (lowestCost == null || cost < lowestCost) {
        best = _applySplits();
        lowestCost = cost;
      }
    }

    return best;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  ///
  /// Returns the cost where a higher number is a worse set of splits or `null`
  /// if the set of splits is completely invalid.
  int _evaluateCost() {
    // Rate this set of lines.
    var cost = 0;

    // Apply any param costs.
    for (var param in _params) {
      if (param.isSplit) cost += param.cost;
    }

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var line = 0;
    var length = _line.indent * SPACES_PER_INDENT;

    // Determine which spans got split. Note that the line may not always
    // contain matched start/end pairs. If a hard newline appears in the middle
    // of a span, the line may contain only the beginning or end of a span. In
    // that case, they will effectively do nothing, which is what we want.
    var spanStarts = {};

    // TODO(rnystrom): Is there a cleaner or faster way of determining this?
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

    for (var chunk in _line.chunks) {
      if (chunk is SpanStartChunk) {
        spanStarts[chunk] = line;
      } else if (chunk is SpanEndChunk) {
        // If the end span is on a different line from the start, pay for it.
        if (spanStarts[chunk.start] != line) cost += chunk.cost;
      } else if (chunk is SplitChunk) {
        if (chunk.param.isSplit) {
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

    if (debug) {
      var params = _params.map(
          (param) => param.isSplit ? param.cost : "_").join(" ");
      var lines = _applySplits()
          .map((line) => line + " " * (_pageWidth - line.length) + "|")
          .join('\n');
      print("--- $params: $cost\n$lines");
    }

    return cost;
  }

  /// Applies the current set of splits to [line] and breaks it into a series
  /// of individual lines.
  ///
  /// Returns the resulting split lines.
  List<String> _applySplits() {
    var lines = [];
    var buffer = new StringBuffer();
    buffer.write(" " * (_line.indent * SPACES_PER_INDENT));

    // Write each chunk in the line.
    for (var chunk in _line.chunks) {
      if (chunk is SplitChunk && chunk.param.isSplit) {
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
  void _dumpLine(Line line) {
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
        var color = split.param.isSplit ? green : gray;

        buffer
            ..write("$color‹")
            ..write(split.param.cost)
            ..write("›$none");
      }
    }

    print(buffer);
  }
}
