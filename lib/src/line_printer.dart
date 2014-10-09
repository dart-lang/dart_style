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
  // TODO(rnystrom): Remove or expose in a more coherent way.
  static bool debug = false;

  final int pageWidth;

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LinePrinter({this.pageWidth});

  /// Convert this [line] to a [String] representation.
  String printLine(Line line) {
    if (debug) _dumpLine(line);

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
    var lowestCost;

    // The set of lines whose splits have the lowest total cost so far.
    var best;

    var rules = new Set<SplitRule>();
    for (var chunk in fullLine.chunks) {
      if (chunk is! RuleChunk) continue;
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

      // Try it out and see how much it costs.
      var splitLines = {};
      var lines = _applySplits(fullLine, rules, splitLines);

      // If we didn't keep it within the page, definitely fail.
      if (lines.any((line) => line.length > pageWidth)) continue;

      // Rate this set of lines.
      var cost = 0;

      for (var rule in rules) {
        var ruleCost = rule.getCost(splitLines[rule]);

        // If a hard constraint failed, abandon this set of splits.
        if (ruleCost == SplitCost.DISALLOW) {
          cost = -1;
          break;
        }

        cost += ruleCost;
      }

      if (cost == -1) continue;

      // Apply any param costs.
      for (var param in params) cost += param.cost;

      // Try to keep characters near the top.
      for (var j = 1; j < lines.length; j++) {
        cost += lines[j].length * j * SplitCost.CHAR;
      }

      if (debug) {
        print("--- $cost\n${lines.map((line) {
          return line + " " * (pageWidth - line.length) + "|";
        }).join('\n')}");
      }

      if (lowestCost == null || cost < lowestCost) {
        best = lines;
        lowestCost = cost;
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
      if (chunk is RuleChunk && chunk.rule != null) {
        // Keep track of this line this chunk ended up on.
        splitLines[chunk.rule].add(lines.length);
      } else if (chunk is SplitChunk && chunk.param.isSplit) {
        lines.add(buffer.toString());
        buffer.clear();
        indent = chunk.indent;
        writeIndent();
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

    var rules = new Map<SplitRule, int>();

    for (var chunk in line.chunks) {
      if (chunk is TextChunk) {
        buffer.write(chunk);
      } else if (chunk is RuleChunk) {
        var rule = rules.putIfAbsent(chunk.rule, () => rules.length);
        buffer.write("$cyan‹$rule›$none");
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
          ..write(split.indent)
          ..write(split.text)
          ..write("›$none");
      }
    }

    print(buffer);
  }
}
