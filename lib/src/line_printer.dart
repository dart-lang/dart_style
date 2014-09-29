// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'line.dart';
import 'splitter.dart';

/// Converts a [Line] to a single flattened [String] (which may span multiple
/// physical lines), applying any [Splitter]s needed to keep the output lines
/// within the page width.
class LinePrinter {
  final int pageWidth;

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LinePrinter({this.pageWidth});

  /// Convert this [line] to a [String] representation.
  String printLine(Line line) {
    if (line.splitters.isEmpty || line.unsplitLength <= pageWidth) {
      // No splitting needed or possible.
      return _printUnsplit(line);
    }

    var lines = _chooseSplits(line);
    if (lines == null) {
      // Could not split it.
      return _printUnsplit(line);
    }

    // TODO(rnystrom): Use configured line separator.
    return lines.join("\n");
  }

  /// Prints [line] without any splitting.
  String _printUnsplit(Line line) {
    var buffer = new StringBuffer();
    buffer.write(" " * (line.indent * SPACES_PER_INDENT));
    buffer.writeAll(line.chunks);

    return buffer.toString();
  }

  /// Chooses which set of splits to apply in [line] to get the most appealing
  /// result.
  ///
  /// Returns the best set of split lines.
  List<String> _chooseSplits(Line fullLine) {
    var bestScore;
    var best;

    var bestSplits;

    // Try every combination of splitters being enabled or disabled.
    // TODO(rnystrom): Is there a faster way we can search this space?
    var splitters = fullLine.splitters.toList();
    for (var i = 0; i < (1 << splitters.length); i++) {
      var s = "";

      // Set a combination of splitters.
      for (var j = 0; j < splitters.length; j++) {
        splitters[j].isSplit = i & (1 << j) != 0;
        s += splitters[j].isSplit ? "1" : "0";
      }

      // Try it out and score it.
      var splitLines = {};
      var lines = _applySplits(fullLine, splitLines);

      // If we didn't keep it within the page, definitely fail.
      if (lines.any((line) => line.length > pageWidth)) continue;

      // Make sure the splitters allow the combination.
      var satisfiedSplitters = splitters.every((splitter) {
        if (splitter.isSplit) {
          return splitter.isValidSplit(splitLines[splitter]);
        } else {
          return splitter.isValidUnsplit(splitLines[splitter]);
        }
      });

      if (!satisfiedSplitters) continue;

      // Splitting into fewer lines is better.
      var score = -lines.length;
      if (bestScore == null || score > bestScore) {
        best = lines;
        bestScore = score;
        bestSplits = splitLines;
      }
    }

    return best;
  }

  /// Applies the current set of splits to [line] and breaks it into a series
  /// of individual lines.
  ///
  /// Returns the resulting split lines. [splitLines] is an output parameter.
  /// It should be passed as an empty map. When this returns, it will be
  /// populated such that each splitter in the line is mapped to a list of the
  /// (zero-based) line indexes that each split for that splitter was output
  /// to.
  List<String> _applySplits(Line line, Map<Splitter, List<int>> splitLines) {
    for (var splitter in line.splitters) {
      splitLines[splitter] = [];
    }

    var indent = line.indent;

    var lines = [];
    var buffer = new StringBuffer();

    writeIndent() {
      buffer.write(" " * (indent * SPACES_PER_INDENT));
    }

    // Indent the first line.
    writeIndent();

    // Write each chunk in the line.
    for (var chunk in line.chunks) {
      if (chunk is TextChunk) {
        buffer.write(chunk.text);
      } else if (chunk is SplitChunk) {
        // Keep track of this line this split ended up on.
        splitLines[chunk.splitter].add(lines.length);

        if (chunk.splitter.isSplit) {
          indent += chunk.indent;
          if (chunk.isNewline) {
            lines.add(buffer.toString());
            buffer.clear();
            writeIndent();
          }
        } else {
          buffer.write(chunk.text);
        }
      } else {
        throw "Unknown Chunk type.";
      }
    }

    // Finish the last line.
    if (!buffer.isEmpty) lines.add(buffer.toString());

    return lines;
  }
}
