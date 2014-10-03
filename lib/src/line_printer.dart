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
    //_dumpLine(line);

    if (!line.hasSplits && line.unsplitLength <= pageWidth) {
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
    // Note that higher scores are *worse*. Code golf!
    var bestScore;
    var best;

    var rules = new Set<SplitRule>();
    for (var chunk in fullLine.chunks) {
      if (chunk is! SplitChunk) continue;
      if (chunk.rule == null) continue;
      rules.add(chunk.rule);
    }

    // See which parameters we can toggle for the line.
    var params = new Set<SplitParam>();
    for (var chunk in fullLine.chunks) {
      if (chunk is! SplitChunk) continue;

      // TODO(rnystrom): Split into sublines at forced parameters and split each
      // one separately.
      if (chunk.param.isForced) continue;
      params.add(chunk.param);
    }

    params = params.toList();

    // Try every combination of params being enabled or disabled.
    // TODO(rnystrom): Search this space more efficiently!
    for (var i = 0; i < (1 << params.length); i++) {
      var s = "";

      // Set a combination of params.
      for (var j = 0; j < params.length; j++) {
        params[j].isSplit = i & (1 << j) != 0;
        s += params[j].isSplit ? "1" : "0";
      }

      // Try it out and score it.
      var splitLines = {};
      var lines = _applySplits(fullLine, rules, splitLines);

      // If we didn't keep it within the page, definitely fail.
      if (lines.any((line) => line.length > pageWidth)) continue;

      // Make sure the rules allow the combination.
      if (!rules.every((rule) => rule.isValid(splitLines[rule]))) continue;

      // Rate this set of lines.
      var score = 0;
      var scoreString = "";

      // Try to keep characters near the top: fewer lines and weighted towards
      // the first lines.
      for (var j = 1; j < lines.length; j++) {
        score += lines[j].length * (j + 2);
        scoreString += " $j:${lines[j].length * (j + 2)}";
      }

      /*
      // Some splits are better than others.
      for (var splitter in splitters) {
        // TODO(rnystrom): Is tuning this by the page width what we want?
        if (splitter.isSplit) {
          score += splitter.score * pageWidth;
          scoreString += " ${splitter.score * pageWidth}${splitter.name}";
        }
      }
      */

      /*
      print("--- $score                                $scoreString\n${lines.map((line) {
        return line + " " * (pageWidth - line.length) + "|";
      }).join('\n')}");
      */

      if (bestScore == null || score < bestScore) {
        best = lines;
        bestScore = score;
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
  List<String> _applySplits(Line line, Set<SplitRule> rules,
      Map<SplitRule, List<int>> splitLines) {
    for (var rule in rules) {
      splitLines[rule] = [];
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
        if (chunk.rule != null) {
          splitLines[chunk.rule].add(lines.length);
        }

        if (chunk.param.isSplit) {
          lines.add(buffer.toString());
          buffer.clear();

          indent = chunk.indent;
          writeIndent();
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
      if (chunk is TextChunk) {
        buffer.write(chunk);
      } else {
        var split = chunk as SplitChunk;

        var color = split.param.isSplit ? green : gray;
        if (split.param is SplitParam) {
          var param = split.param as SplitParam;
          if (param.isForced) {
            color = magenta;
          }
        }

        buffer
            ..write("$color‹")
            ..write("t" * split.indent)
            ..write(split.text)
            ..write("›$none");
      }
    }

    print(buffer);
  }
}
