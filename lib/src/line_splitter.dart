// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'dart:math' as math;

import 'chunk.dart';
import 'debug.dart' as debug;
import 'line_prefix.dart';
import 'line_writer.dart';
import 'rule/rule.dart';

/// Takes a series of [Chunk]s and determines the best way to split them into
/// lines of output that fit within the page width (if possible).
///
/// Imagine a naïve solution. You start at the first chunk in the list and work
/// your way forward. For each chunk, you try every possible value of the rule
/// that the chunk uses. Then, you ask the rule if that chunk should split or
/// not when the rule has that value. If it does, then you try every possible
/// way you could modify the expression nesting context at that point.
///
/// For each of those possible results, you start with that as a partial
/// solution. You move onto the next chunk and repeat the process, building on
/// to that partial solution. When you reach the last chunk, you determine the
/// cost of that set of rule values and keep track of the best one.
///
/// Once you've tried every single possible permutation of rule values and
/// nesting stacks, you will have exhaustively covered every possible way the
/// line can be split and you'll know which one had the lowest cost. That's
/// your result.
///
/// The obvious problem is that this is exponential in the number of values for
/// each rule and the expression nesting levels, both of which can be quite
/// large with things like long method chains containing function literals,
/// large collection literals, etc. To tame that, this uses dynamic programming.
///
/// As the naïve solver is working its way down the chunks, it's building up a
/// partial solution. This solution has:
///
/// * A length—the number of chunks in it.
/// * The set of rule values we have selected for the rules used by those
///   chunks.
/// * The expression nesting stack that is currently active at the point where
///   the current chunk splits.
///
/// We'll call this partial solution a [LinePrefix]. The naïve solution starts
/// with an empty prefix (zero length, no rule values, no expression nesting).
/// It grabs the next chunk after that prefix and says, OK, given this prefix
/// what are all of the possible ways we can split that chunk (rule values and
/// nesting stacks). Create a new, one-chunk-longer prefix for each of those
/// and then recursively solve each of their suffixes.
///
/// Normally, this would basically be a depth-first traversal of the entire
/// possible solution space. However, there is a simple optimization we can
/// make. When brute forcing the solution tree, we will often solve many
/// prefixes with the same length.
///
/// For example, if the first chunk's rule can take three different values, we
/// will solve three line prefixes of length one, one for each rule value.
/// Those in turn may have lots of permutations leading to even more solutions
/// all with line prefixes of length two, and so on.
///
/// In many cases, we have to treat these line prefixes separately. If two
/// prefixes have the same length, but fix a different value for some rule, they
/// may lead to different ways of splitting the suffix since that rule may
/// appear in a later chunk too.
///
/// But in many cases, the line prefixes are equivalent. For example, consider:
///
///     function(
///         first(arg, arg, arg, arg, arg, arg),
///         second,
///         third(arg, arg, arg, arg, arg, arg));
///
/// The line splitter will try a number of different ways to split the argument
/// list to `first`. For each of those, it then has to try all of the different
/// ways it could split `third`. *However*, those two are unrelated. The way
/// you split `first` has no impact on how you split `third`.
///
/// The precise way to state that is that as the line prefix grows *past*
/// `first()` and its argument list, it contains *less* state. It discards the
/// rule value it selected for the argument list rule since that rule doesn't
/// appear anywhere in the suffix and can't affect it. Any expression nesting
/// inside the argument list has been popped off by the time we get to `second`.
///
/// We'll try every possible way to split `first()`'s argument list and then
/// recursively solve the remainder of the line for each of those possible
/// splits. But each of those remainders will end up having identical prefixes.
/// For any given [LinePrefix], there is a single best solution for the suffix.
/// So, once we've found it, we can just reuse it the next time that same
/// prefix comes up.
///
/// In other words, we add a memoization table, [_bestSplits]. It is a map from
/// [LinePrefix]es to [SplitSet]s. For each prefix, it stores the best set of
/// splits to use for the following suffix. With this, instead of exploring the
/// entire solution *tree*, which would be exponential, we just traverse the
/// solution *graph* where entire branches of the tree that are identical
/// collapse back together.
///
/// The trick to making this work is storing the minimal amount of data in the
/// line prefix to *uniquely* identify a suffix while still collapsing as many
/// branches as possible. In practice, this means aggressively forgetting state
/// when the prefix grows. In particular, we do not need to keep track of
/// rule values we selected in the prefix if that rule does not affect anything
/// in the suffix.
///
/// There are a couple of other smaller scale optimizations too. If we ever hit
/// a solution whose cost is zero, we know we won't do better, so we stop
/// searching. If we make it to the end of the chunk list and we haven't gone
/// past the end of the line, we know we don't need to split anywhere.
///
/// But the memoization is the main thing that makes this tractable.
class LineSplitter {
  final LineWriter _writer;

  /// The list of chunks being split.
  final List<Chunk> _chunks;

  /// The number of characters of additional indentation to apply to each line.
  ///
  /// This is used when formatting blocks to get the output into the right
  /// column based on where the block appears.
  final int _blockIndentation;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, SplitSet>{};

  /// The rules that appear in the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _prefixRules = <Set<Rule>>[];

  /// The rules that appear after the first `n` chunks of the line where `n` is
  /// the index into the list.
  final _suffixRules = <Set<Rule>>[];

  /// Creates a new splitter for [_writer] that tries to fit [chunks] into the
  /// page width.
  LineSplitter(this._writer, this._chunks, this._blockIndentation);

  /// Convert the line to a [String] representation.
  ///
  /// It will determine how best to split it into multiple lines of output and
  /// write the result to [writer].
  ///
  /// [firstLineIndent] is the number of characters of whitespace to prefix the
  /// first line of output with.
  SplitSolution apply(int firstLineIndent, {bool flushLeft}) {
    if (debug.traceSplitter) {
      debug.log(debug.green("\nSplitting:"));
      debug.dumpChunks(0, _chunks);
      debug.log();
    }

    // Ignore the trailing rule on the last chunk since it isn't used for
    // anything.
    var ruleChunks = _chunks.take(_chunks.length - 1);

    // Pre-calculate the set of rules appear before and after each length. We
    // use these frequently when creating [LinePrefix]es and they only depend
    // on the length, so we can cache them up front.
    for (var i = 0; i < _chunks.length; i++) {
      _prefixRules.add(ruleChunks.take(i).map((chunk) => chunk.rule).toSet());
      _suffixRules.add(ruleChunks.skip(i).map((chunk) => chunk.rule).toSet());
    }

    var prefix = new LinePrefix(firstLineIndent + _blockIndentation,
        flushLeft: flushLeft);
    var solution = new SplitSolution(prefix);
    _tryChunkRuleValues(solution, prefix);
    return solution;
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

    var solution = new SplitSolution(prefix);
    _tryChunkRuleValues(solution, prefix);

    if (debug.traceSplitter) {
      debug.unindent();
      debug.log("best splits for $prefix = ${solution.splits}");
    }

    return _bestSplits[prefix] = solution.splits;
  }

  /// Updates [solution] with the best rule value selection for the chunk
  /// immediately following [prefix].
  void _tryChunkRuleValues(SplitSolution solution, LinePrefix prefix) {
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
        _tryRuleValue(solution, prefix, value);
      }
    } else if (value == -1) {
      // A -1 "value" means, "any non-zero value". In other words, the rule has
      // to split somehow, but can split however it chooses.
      for (value = 1; value < chunk.rule.numValues; value++) {
        _tryRuleValue(solution, prefix, value);
      }
    } else {
      // Otherwise, it's constrained to a single value, so use it.
      _tryRuleValue(solution, prefix, value);
    }
  }

  /// Updates [solution] with the best solution that can be found by setting
  /// the chunk after [prefix]'s rule to [value].
  void _tryRuleValue(SplitSolution solution, LinePrefix prefix, int value) {
    // If we already have an unbeatable solution, don't bother trying this one.
    if (solution.cost == 0) return;

    var chunk = _chunks[prefix.length];

    if (chunk.rule.isSplit(value, chunk)) {
      // The chunk is splitting in an expression, so try all of the possible
      // nesting combinations.
      var ruleValues = _advancePrefix(prefix, value);
      var longerPrefixes = prefix.split(chunk, _blockIndentation, ruleValues);
      for (var longerPrefix in longerPrefixes) {
        _tryLongerPrefix(solution, prefix, longerPrefix);

        // If we find an unbeatable solution, don't try any more.
        if (solution.cost == 0) break;
      }
    } else {
      // We didn't split here, so add this chunk and its rule value to the
      // prefix and continue on to the next.
      var extended = prefix.extend(_advancePrefix(prefix, value));
      _tryChunkRuleValues(solution, extended);
    }
  }

  /// Updates [solution] with the solution for [prefix] assuming it uses
  /// [longerPrefix] for the next chunk.
  void _tryLongerPrefix(
      SplitSolution solution, LinePrefix prefix, LinePrefix longerPrefix) {
    var remaining = _findBestSplits(longerPrefix);

    // If it wasn't possible to split the suffix given this nesting stack,
    // skip it.
    if (remaining == null) return;

    solution.update(this, remaining.add(prefix.length, longerPrefix.column));
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
      var ruleValue =
          prefixRule == nextRule ? value : prefix.ruleValues[prefixRule];

      if (suffixRules.contains(prefixRule)) {
        // If the same rule appears in both the prefix and suffix, then preserve
        // its exact value.
        updatedValues[prefixRule] = ruleValue;
      }

      // If we haven't specified any value for this rule in the prefix, it
      // doesn't place any constraint on the suffix.
      if (ruleValue == null) continue;

      // Enforce the constraints between rules.
      for (var suffixRule in suffixRules) {
        if (suffixRule == prefixRule) continue;

        // See if the prefix rule's value constrains any values in the suffix.
        var value = prefixRule.constrain(ruleValue, suffixRule);

        // Also consider the backwards case, where a later rule in the suffix
        // constrains a rule in the prefix.
        if (value == null) {
          value = suffixRule.reverseConstrain(ruleValue, prefixRule);
        }

        if (value != null) {
          updatedValues[prefixRule] = ruleValue;
          updatedValues[suffixRule] = value;
        }
      }
    }

    return updatedValues;
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of rules.
  int _evaluateCost(LinePrefix prefix, SplitSet splits) {
    assert(splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    var length = prefix.column;

    var splitRules = new Set();

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _writer.pageWidth) {
        cost += (length - _writer.pageWidth) * Cost.overflowChar;
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
            splitRules.add(chunk.rule);
            cost += chunk.rule.cost;
          }

          // Include the cost of the nested block.
          if (chunk.blockChunks.isNotEmpty) {
            cost += _writer.formatBlock(chunk, splits.getColumn(i)).cost;
          }

          // Start the new line.
          length = splits.getColumn(i);
        } else {
          if (chunk.spaceWhenUnsplit) length++;

          // Include the nested block inline, if any.
          length += chunk.unsplitBlockLength;
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
class SplitSolution {
  /// The prefix whose suffix we are finding a solution for.
  final LinePrefix _prefix;

  /// The best set of splits currently found.
  SplitSet get splits => _bestSplits;
  SplitSet _bestSplits;

  /// The lowest cost currently found.
  int get cost => _lowestCost;
  int _lowestCost;

  /// Whether a solution that fits within a page has been found yet.
  bool get isAdequate => _lowestCost != null && _lowestCost < Cost.overflowChar;

  SplitSolution(this._prefix);

  /// Compares [splits] to the best solution found so far and keeps it if it's
  /// better.
  void update(LineSplitter splitter, SplitSet splits) {
    var cost = splitter._evaluateCost(_prefix, splits);

    if (_lowestCost == null || cost < _lowestCost) {
      _bestSplits = splits;
      _lowestCost = cost;
    }

    if (debug.traceSplitter) {
      var best = _bestSplits == splits ? " (best)" : "";
      debug.log(debug.gray("$_prefix $splits \$$cost$best"));
      debug.dumpLines(splitter._chunks, _prefix, splits);
      debug.log();
    }
  }
}

/// An immutable, persistent set of enabled split [Chunk]s.
///
/// For each chunk, this tracks if it has been split and, if so, what the
/// chosen column is for the following line.
///
/// Internally, this uses a sparse parallel list where each element corresponds
/// to the column of the chunk at that index in the chunk list, or `null` if
/// there is no active split there. This had about a 10% perf improvement over
/// using a [Set] of splits or a persistent linked list of split index/indent
/// pairs.
class SplitSet {
  List<int> _columns;

  /// Creates a new empty split set.
  SplitSet() : this._(const []);

  SplitSet._(this._columns);

  /// Returns a new [SplitSet] containing the union of this one and the split
  /// at [index] with next line starting at [column].
  SplitSet add(int index, int column) {
    var newIndents = new List(math.max(index + 1, _columns.length));
    newIndents.setAll(0, _columns);
    newIndents[index] = column;

    return new SplitSet._(newIndents);
  }

  /// Returns `true` if the chunk at [splitIndex] should be split.
  bool shouldSplitAt(int index) =>
      index < _columns.length && _columns[index] != null;

  /// Gets the zero-based starting column for the chunk at [index].
  int getColumn(int index) => _columns[index];

  String toString() {
    var result = [];
    for (var i = 0; i < _columns.length; i++) {
      if (_columns[i] != null) {
        result.add("$i:${_columns[i]}");
      }
    }

    return result.join(" ");
  }
}
