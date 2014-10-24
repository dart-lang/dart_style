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
  final _rules = new Set<SplitRule>();

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

    // Find all of the rules applied to the line.
    for (var chunk in _line.chunks) {
      if (chunk is! RuleChunk) continue;
      if (chunk.rule == null) continue;
      _rules.add(chunk.rule);
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
      var allowed = true;
      var previousParams = new Set();
      var thisLineParams = new Set();
      for (var chunk in _line.chunks) {
        if (chunk is! SplitChunk) continue;

        if (chunk.param.isSplit) {
          // Splitting here, so every param we've seen so far is now on a
          // previous line.
          previousParams.addAll(thisLineParams);
          thisLineParams.clear();
        } else {
          if (previousParams.contains(chunk.param)) {
            allowed = false;
            break;
          }

          thisLineParams.add(chunk.param);
        }
        var param = chunk.param;
      }

      if (!allowed) continue;

      // Try it out and see how much it costs.
      var ruleLines = {};
      var lines = _applySplits(ruleLines);
      // TODO(rnystrom): Don't need to fully generate the split lines just to
      // evaluate them. Consider optimizing by not doing that.
      var cost = _evaluateCost(lines, ruleLines);

      if (lowestCost == null || cost < lowestCost) {
        best = lines;
        lowestCost = cost;
      }
    }

    return best;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines with the [RuleChunk]s distributed into
  /// [ruleLines].
  ///
  /// Returns [SplitCost.DISALLOW] if [lines] is not an allowed solution because
  /// the set of chosen splits violates the guidelines. Otherwise, returns a
  /// non-negative number where higher values indicate less preferred solutions.
  int _evaluateCost(List<String> lines, Map<SplitRule, List<int>> ruleLines) {
    // Rate this set of lines.
    var cost = 0;

    for (var rule in _rules) {
      cost += rule.getCost(ruleLines[rule]);
    }

    // Apply any param costs.
    for (var param in _params) cost += param.cost;

    // Punish lines that went over the length. We don't rule these out
    // completely because it may be that the only solution still goes over
    // (for example with long string literals).
    for (var line in lines) {
      if (line.length > _pageWidth) {
        cost += (line.length - _pageWidth) * SplitCost.OVERFLOW_CHAR;
      }
    }

    if (debug) {
      var params = _params.map(
          (param) => param.isSplit ? param.cost : "_").join(" ");
      print("--- $params: $cost\n${lines.map((line) {
        return line + " " * (_pageWidth - line.length) + "|";
      }).join('\n')}");
    }

    return cost;
  }

  /// Applies the current set of splits to [line] and breaks it into a series
  /// of individual lines.
  ///
  /// Returns the resulting split lines. [ruleLines] is an output parameter.
  /// It should be passed as an empty map. When this returns, it will be
  /// populated such that each [SplitRule] in the line is mapped to a list of
  /// the (zero-based) line indexes that each [RuleChunk] for that splitter was
  /// output to.
  List<String> _applySplits(Map<SplitRule, List<int>> ruleLines) {
    for (var rule in _rules) {
      ruleLines[rule] = [];
    }

    var indent = _line.indent;

    // TODO(rnystrom): We can optimize this by calculating the cost without
    // actually building up the complete strings for each line. All we really
    // need is line lengths and rule lines.
    var lines = [];
    var buffer = new StringBuffer();

    writeIndent() {
      buffer.write(" " * (indent * SPACES_PER_INDENT));
    }

    // Indent the first line.
    writeIndent();

    // Write each chunk in the line.
    for (var chunk in _line.chunks) {
      if (chunk is RuleChunk && chunk.rule != null) {
        // Keep track of this line this chunk ended up on.
        ruleLines[chunk.rule].add(lines.length);
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
