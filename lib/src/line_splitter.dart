// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'dart:math' as math;

import 'chunk.dart';
import 'debug.dart' as debug;
import 'line_prefix.dart';
import 'rule.dart';

/// The number of spaces in a single level of indentation.
const spacesPerIndent = 2;

/// The number of indentation levels in a single level of expression nesting.
const indentsPerNest = 2;

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

  /// The leading indentation at the beginning of the first line.
  final int _indent;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, SplitSet>{};

  /// The rules that appear in the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _prefixRules = <Set<Rule>>[];

  /// The rules that appear after the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _suffixRules = <Set<Rule>>[];

  /// Creates a new splitter that tries to fit a series of chunks within a
  /// given page width.
  LineSplitter(this._lineEnding, this._pageWidth, this._chunks, this._indent) {
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
    if (debug.traceFormatter) {
      debug.log(debug.green("\nSplitting:"));
      debug.dumpChunks(_chunks);
      debug.log();
    }

    // Pre-calculate the set of rules appear before and after each length. We
    // use these frequently when creating [LinePrefix]es and they only depend
    // on the length, so we can cache them up front.
    for (var i = 0; i < _chunks.length; i++) {
      _prefixRules.add(_chunks.take(i).map((chunk) => chunk.rule).toSet());
      _suffixRules.add(_chunks.skip(i).map((chunk) => chunk.rule).toSet());
    }

    // TODO(rnystrom): One optimization we could perform is to merge spans that
    // have the same range into a single span with a summed cost.

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
      } else {
        if (chunk.spaceWhenUnsplit) buffer.write(" ");
      }
    }

    return selection;
  }

  /// Finds the best set of splits to apply to the remainder of the chunks
  /// following [prefix].
  ///
  /// This can only be called for a suffix that begins a new line. (In other
  /// words, the last chunk in the prefix cannot be unsplit.)
  SplitSet _findBestSplits(LinePrefix prefix) {
    // Use the memoized result if we have it.
    if (_bestSplits.containsKey(prefix)) {
      if (debug.traceSplitter) {
        debug.log("memoized splits for $prefix = ${_bestSplits[prefix]}");
      }
      return _bestSplits[prefix];
    }

    if (debug.traceSplitter) {
      debug.log("find splits for $prefix");
      debug.indent();
    }

    var indent = prefix.getNextLineIndent(_chunks, _indent);

    var solution = new Solution(prefix, indent);
    _tryChunkRuleValues(solution, prefix, indent * spacesPerIndent);

    if (debug.traceSplitter) {
      debug.unindent();
      debug.log("best splits for $prefix = ${solution.splits}");
    }

    return _bestSplits[prefix] = solution.splits;
  }

  /// Updates [solution] with the best rule value selection for the chunk
  /// immediately following [prefix].
  void _tryChunkRuleValues(Solution solution, LinePrefix prefix, int length) {
    // If we made it to the end, this prefix can be solved without splitting
    // any chunks.
    if (prefix.length == _chunks.length - 1) {
      solution.update(this, new SplitSet());
      return;
    }

    var chunk = _chunks[prefix.length];

    // See if we've already selected a value for the rule.
    var value = prefix.ruleValues[chunk.rule];

    if (value == null) {
      // No, so try every possible value for the rule.
      for (value = 0; value < chunk.rule.numValues; value++) {
        _tryRuleValue(solution, prefix, value, length);
      }
    } else {
      // Otherwise, it's constrained to a single value, so use it.
      _tryRuleValue(solution, prefix, value, length);
    }
  }

  /// Updates [solution] with the best solution that can be found by setting
  /// the chunk after [prefix]'s rule to [value].
  void _tryRuleValue(Solution solution, LinePrefix prefix, int value,
      int length) {
    var chunk = _chunks[prefix.length];

    var isSplit = chunk.rule.isSplit(value, chunk);
    if (!isSplit) {
      // If this chunk bumps us past the page limit and we already have a
      // solution that fits, no solution past this chunk will beat that, so
      // stop looking.
      length += chunk.length;
      if (length > _pageWidth && solution.isAdequate) return;
    }

    var ruleValues = _advancePrefix(prefix, value);

    if (!isSplit) {
      // We didn't split here, so add this chunk and its rule value to the
      // prefix and continue on to the next.
      var added = prefix.addChunk(ruleValues);
      _tryChunkRuleValues(solution, added, length);
    } else if (!chunk.isInExpression) {
      // The chunk is splitting at a statement boundary, so we don't have to
      // worry about nesting stacks.
      _tryLongerPrefix(solution, prefix, prefix.addStatement(ruleValues));
    } else {
      // The chunk is splitting in an expression, so try all of the possible
      // nesting combinations.
      var longerPrefixes = prefix.addExpressionSplit(chunk, ruleValues);
      for (var longerPrefix in longerPrefixes) {
        _tryLongerPrefix(solution, prefix, longerPrefix);
      }
    }
  }

  /// Updates [solution] with the solution for [prefix] assuming it uses
  /// [longerPrefix] for the next chunk.
  void _tryLongerPrefix(Solution solution, LinePrefix prefix,
        LinePrefix longerPrefix) {
    var remaining = _findBestSplits(longerPrefix);

    // If it wasn't possible to split the suffix given this nesting stack,
    // skip it.
    if (remaining == null) return;

    var splits = remaining.add(prefix.length, longerPrefix.nestingIndent);
    solution.update(this, splits);
  }

  /// Determines the set of rule values for a new [LinePrefix] one chunk longer
  /// than [prefix] whose rule on the new last chunk has [value].
  ///
  /// Returns a map of [Rule]s to values for those rules for the values that
  /// span the prefix and suffix of the [LinePrefix].
  Map<Rule, int> _advancePrefix(LinePrefix prefix, int value) {
    // Get the rules that appear in both in and after the new prefix. These are
    // the rules that already have values that the suffix needs to honor.
    var prefixRules = _prefixRules[prefix.length + 1];
    var suffixRules = _suffixRules[prefix.length + 1];

    var nextRule = _chunks[prefix.length].rule;
    var updatedValues = {};

    for (var prefixRule in prefixRules) {
      var ruleValue = prefixRule == nextRule
          ? value
          : prefix.ruleValues[prefixRule];

      if (suffixRules.contains(prefixRule)) {
        // If the same rule appears in both the prefix and suffix, then preserve
        // its exact value.
        updatedValues[prefixRule] = ruleValue;
      }

      // If we haven't specified any value for this rule in the prefix, it
      // doesn't place any constraint on the suffix.
      if (ruleValue == null) continue;

      // Track the implications between rules. If this rule is split, then
      // any rule it implies must split too. Conversely, if it is not fully
      // split then any rule that implies it must also not split.
      if (ruleValue == prefixRule.fullySplitValue) {
        // The prefix rule split so we have to force the implied rules in the
        // suffix to split too.
        for (var suffixRule in suffixRules) {
          if (prefixRule.implies.contains(suffixRule)) {
            // TODO(bob): See TODO below about the next line.
            updatedValues[prefixRule] = ruleValue;
            updatedValues[suffixRule] = suffixRule.fullySplitValue;
          }
        }
      } else {
        // Also consider the backwards case, where a later rule in the suffix
        // implies a rule in the prefix. If prefix rule did not split, then
        // don't let the suffix rule that implies it split either since that
        // would violate the implication.
        for (var suffixRule in suffixRules) {
          if (suffixRule.implies.contains(prefixRule)) {
            // TODO(bob): See TODO below about the next line.
            updatedValues[prefixRule] = ruleValue;
            updatedValues[suffixRule] = 0;
          }
        }
      }
    }

    // TODO(bob): I don't think I fully understand these, though they seem to
    // be needed to get correct behavior. I think it has something to do with
    // ensuring that a rule that implies other rules is preserved so that later
    // extensions of the resulting prefix maintain that early rule setting. I'm
    // not sure if there's a cleaner way to handle that. I'm also not sure if
    // it makes LinePrefixes unnecessarily precise and worsens the memoization
    // hits.

    return updatedValues;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of params.
  int _evaluateCost(LinePrefix prefix, int indent, SplitSet splits) {
    assert(splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    var length = indent * spacesPerIndent;

    var splitRules = new Set();

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * Cost.overflowChar;
      }
    }

    // The set of spans that contain chunks that ended up splitting. We store
    // these in a set so a span's cost doesn't get double-counted if more than
    // one split occurs in it.
    var splitSpans = new Set();

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      length += chunk.text.length;

      if (i < _chunks.length - 1) {
        if (splits.shouldSplitAt(i)) {
          endLine();

          splitSpans.addAll(chunk.spans);

          if (chunk.rule != null && !splitRules.contains(chunk.rule)) {
            // Don't double-count rules if multiple splits share the same
            // rule.
            // TODO(rnystrom): Is this needed? Can we actually let splits that
            // share a rule accumulate cost?
            splitRules.add(chunk.rule);
            cost += chunk.rule.cost;
          }

          // Start the new line.
          length = (chunk.indent + splits.getNesting(i)) * spacesPerIndent;
        } else {
          if (chunk.spaceWhenUnsplit) length++;
        }
      }
    }

    // Add the costs for the spans containing splits.
    for (var span in splitSpans) cost += span.cost;

    // Finish the last line.
    endLine();

    return cost;
  }
}

/// Keeps track of the best set of splits found so far for a suffix of some
/// prefix.
class Solution {
  /// The prefix whose suffix we are finding a solution for.
  final LinePrefix _prefix;

  /// The indentation at the beginning of the suffix.
  final int _indent;

  SplitSet _bestSplits;
  int _lowestCost;

  /// The best set of splits currently found.
  SplitSet get splits => _bestSplits;

  /// Whether a solution that fits within a page has been found yet.
  bool get isAdequate => _lowestCost != null && _lowestCost < Cost.overflowChar;

  Solution(this._prefix, this._indent);

  /// Compares [splits] to the best solution found so far and keeps it if it's
  /// better.
  void update(LineSplitter splitter, SplitSet splits) {
    var cost = splitter._evaluateCost(_prefix, _indent, splits);

    // TODO(bob): Is weight still needed?
    if (_lowestCost == null ||
        cost < _lowestCost/* ||
        (cost == _lowestCost && splits.weight > _bestSplits.weight)*/) {
      _bestSplits = splits;
      _lowestCost = cost;
    }

    if (debug.traceSplitter) {
      var best = _bestSplits == splits ? " (best)" : "";
      debug.log(debug.gray("$_prefix $splits \$$cost$best"));
      debug.dumpLines(splitter._chunks, _indent, _prefix, splits);
      debug.log();
    }
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

  // TODO(bob): Is this still needed with split rules?
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
