// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'line.dart';
import 'splitter.dart';

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

  /// The sets of enabled [SplitParams] that have been tried already when
  /// looking for a solution.
  final _paramSets = new List<ParamSet>();

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
      // TODO(bob): Hack temp. Have to still apply splits to handle forced
      // splits when an AllSplit is forced by containing a block.
      // Find all of the rules applied to the line.
      var indent = _line.indent;
      var buffer = new StringBuffer();

      writeIndent() {
        buffer.write(" " * (indent * SPACES_PER_INDENT));
      }

      // Indent the first line.
      writeIndent();

      // Write each chunk in the line.
      var needLine = false;
      for (var chunk in _line.chunks) {
        if (chunk is SplitChunk && chunk.param.isForced) {
          needLine = true;
          indent = chunk.indent;
        } else {
          if (needLine) {
            buffer.writeln();
            writeIndent();
            needLine = false;
          }
          buffer.write(chunk.text);
        }
      }

      return buffer.toString();

      /*
      // No splitting needed or possible.
      return _printUnsplit();
      */
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

      // TODO(rnystrom): Split into sublines at forced parameters and split each
      // one separately.
      if (chunk.param.isForced) continue;
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

  /*
  /// Chooses which set of splits to apply to get the most appealing result.
  ///
  /// Returns the best set of split lines.
  List<String> _chooseSplits() {
    var lowestCost;

    // The set of lines whose splits have the lowest total cost so far.
    var best;

    // Try every combination of params being enabled or disabled.
    // TODO(rnystrom): Search this space more efficiently!
    for (var i = 0; i < (1 << _params.length); i++) {
      // Set a combination of params.
      for (var j = 0; j < _params.length; j++) {
        _params[j].isSplit = i & (1 << j) != 0;
      }

      // Try it out and see how much it costs.
      var ruleLines = {};
      var lines = _applySplits(ruleLines);
      var cost = _evaluateCost(lines, ruleLines);
      if (cost == SplitCost.DISALLOW) continue;

      if (lowestCost == null || cost < lowestCost) {
        best = lines;
        lowestCost = cost;
      }
    }

    return best;
  }
  */

  /// Chooses which set of splits to apply to get the most appealing result.
  ///
  /// Returns the best set of split lines.
  List<String> _chooseSplits() {
    // TODO(bob): Seed with empty param set. Can't be solution since we
    // handled case already.
    _paramSets.add(new ParamSet(new Set()));
    // TODO(bob): Is this right?
    _paramSets.last.cost = -1;

    var bestOverhang;
    var bestOverhangCost;

    while (_nextParamSet()) {
      // Try it out and see how much it costs.
      _paramSets.last.apply(_params);
      var ruleLines = {};
      var lines = _applySplits(ruleLines);
      var cost = _evaluateCost(lines, ruleLines, true);
      if (cost == SplitCost.DISALLOW) continue;

      // TODO(bob): Hack! Do something cleaner!
      // If the solution doesn' fit, keep trying.
      if (cost >= SplitCost.OVERFLOW_CHAR) {
        // Keep track of the best set of lines that do overhang. If we couldn't
        // find a solution that fits in the page width, we'll fall back to this.
        if (bestOverhangCost == null || cost < bestOverhangCost) {
          bestOverhang = lines;
          bestOverhangCost = cost;
        }

        continue;
      }

      // If we got here it's valid and has the lowest cost.
      return lines;
    }

    // If we got here, we couldn't find an appropriate set of splits that fit
    // in the page width.
    return bestOverhang;
  }

  // TODO(bob): Doc.
  bool _nextParamSet() {
    var worstCost = _paramSets.last.cost;

    var bestParamSet;

    // Each new solution -- set of params -- will always be one of the
    // previously tried sets with one additional param set.
    for (var previousSet in _paramSets) {
      // Try adding each parameter (by itself) to this existing subset.
      for (var i = 0; i < _params.length; i++) {
        // Skip subsets that already contain this number.
        // TODO(rnystrom): Doing .contains here is slow. Use full-size list?
        if (previousSet.params.contains(_params[i])) continue;

        var paramSet = previousSet.refine(_params[i]);
        paramSet.cost = _calculateCost(paramSet);

        // If this param set isn't as bad as the last set we tried, then we
        // must have already tried it before.
        if (paramSet.cost < worstCost) continue;

        // If this param is worse than the best candidate so far, ignore it.
        if (bestParamSet != null && paramSet.cost > bestParamSet.cost) continue;

        // We may still have tried it before if it has the exact same cost as
        // the worst set we've already tried. Check for that.
        var exists = false;
        for (var j = _paramSets.length - 1; j >= 0; j--) {
          // We can stop once we reach subsets with lower costs since we're only
          // worried about ones with the same cost.
          if (_paramSets[j].cost < worstCost) break;

          // TODO(bob): Optimize.
          if (_paramSets[j] == paramSet) {
            exists = true;
            break;
          }
        }

        if (exists) continue;

        bestParamSet = paramSet;
      }
    }

    // TODO(bob): Return false?
    if (bestParamSet == null) return false;

    _paramSets.add(bestParamSet);
    return true;
  }

  int _calculateCost(ParamSet params) {
    params.apply(_params);

    // Try it out and see how much it costs.
    var ruleLines = {};
    var lines = _applySplits(ruleLines);
    var cost = _evaluateCost(lines, ruleLines, false);
    // TODO(bob): Handle DISALLOW better.
    if (cost == SplitCost.DISALLOW) return 0;
    return cost;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines with the [RuleChunk]s distributed into
  /// [ruleLines].
  ///
  /// Returns [SplitCost.DISALLOW] if [lines] is not an allowed solution because
  /// the set of chosen splits violates the guidelines. Otherwise, returns a
  /// non-negative number where higher values indicate less preferred solutions.
  int _evaluateCost(List<String> lines, Map<SplitRule, List<int>> ruleLines,
      bool countOverhang) {
    // Rate this set of lines.
    var cost = 0;

    for (var rule in _rules) {
      var ruleCost = rule.getCost(ruleLines[rule]);

      // If a hard constraint failed, abandon this set of splits.
      if (ruleCost == SplitCost.DISALLOW) return SplitCost.DISALLOW;

      cost += ruleCost;
    }

    // Apply any param costs.
    for (var param in _params) cost += param.cost;

    // Try to keep characters near the top.
    for (var j = 1; j < lines.length; j++) {
      cost += lines[j].length * j * SplitCost.CHAR;
    }

    // Punish lines that went over the length. We don't rule these out
    // completely because it may be that the only solution still goes over
    // (for example with long string literals).
    if (countOverhang) {
      for (var line in lines) {
        if (line.length > _pageWidth) {
          cost += (line.length - _pageWidth) * SplitCost.OVERFLOW_CHAR;
        }
      }
    }

    if (debug) {
      print("--- $cost\n${lines.map((line) {
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

class ParamSet {
  final Set<SplitParam> params;

  // TODO(bob): Make immutable.
  int cost;

  ParamSet(this.params);

  void apply(List<SplitParam> allParams) {
    for (var param in allParams) {
      param.isSplit = params.contains(param);
    }
  }

  /// Returns a new [ParamSet] that contains all of the params of this one
  /// along with [param].
  ParamSet refine(SplitParam param) => new ParamSet(params.toSet()..add(param));

  bool operator ==(ParamSet other) {
    if (params.length != other.params.length) return false;

    for (var param in params) if (!other.params.contains(param)) return false;
    return true;
  }

  String toString() {
    var buffer = new StringBuffer();
    buffer.write("(");
    buffer.writeAll(params, ", ");
    buffer.write(" : ");
    buffer.write(cost);
    buffer.write(")");
    return buffer.toString();
  }
}