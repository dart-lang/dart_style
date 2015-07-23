// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'package:collection/priority_queue.dart';

import 'chunk.dart';
import 'debug.dart' as debug;
import 'line_writer.dart';
import 'rule/rule.dart';
import 'rule_set.dart';

/// To ensure the solver doesn't go totally pathological on giant code, we cap
/// it at a fixed number of attempts.
///
/// If the optimal solution isn't found after this many tries, it just uses the
/// best it found so far.
const _maxAttempts = 50000;

/// Takes a set of chunks and determines the best values for its rules in order
/// to fit it inside the page boundary.
///
/// This problem is exponential in the number of rules and a single expression
/// in Dart can be quite large, so it isn't feasible to brute force this. For
/// example:
///
///     outer(
///         fn(1 + 2, 3 + 4, 5 + 6, 7 + 8),
///         fn(1 + 2, 3 + 4, 5 + 6, 7 + 8),
///         fn(1 + 2, 3 + 4, 5 + 6, 7 + 8),
///         fn(1 + 2, 3 + 4, 5 + 6, 7 + 8));
///
/// There are 509,607,936 ways this can be split.
///
/// The problem is even harder because we may not be able to easily tell if a
/// given solution is the best one. It's possible that there is *no* solution
/// that fits in the page (due to long strings or identifiers) so the winning
/// solution may still have overflow characters. This makes it hard to know
/// when we are done and can stop looking.
///
/// There are a couple of pieces of domain knowledge we use to cope with this:
///
/// - Changing a rule from unsplit to split will never lower its cost. A
///   solution with all rules unsplit will always be the one with the lowest
///   cost (zero). Conversely, setting all of its rules to the maximum split
///   value will always have the highest cost.
///
///   (You might think there is a converse rule about overflow characters. The
///   solution with the fewest splits will have the most overflow, and the
///   solution with the most splits will have the least overflow. Alas, because
///   of indentation, that isn't always the case. Adding a split may *increase*
///   overflow in some cases.)
///
/// - If all of the chunks for a rule are inside lines that already fit in the
///   page, then splitting that rule will never improve the solution.
///
/// We start off with a [SolveState] where all rules are unbound (which
/// implicitly treats them as unsplit). For a given solve state, we can produce
/// a set of expanded states that takes some of the rules in the first long
/// line and bind them to split values. This always produces new solve states
/// with higher cost (but often fewer overflow characters) than the parent
/// state.
///
/// We take these expanded states and add them to a work list sorted by cost.
/// Since unsplit rules always have lower cost solutions, we know that no state
/// we enqueue later will ever have a lower cost than the ones we already have
/// enqueued.
///
/// Then we keep pulling states off the work list and expanding them and adding
/// the results back into the list. We do this until we hit a solution where
/// all characters fit in the page. The first one we find will have the lowest
/// cost and we're done.
///
/// We also keep running track of the best solution we've found so far that
/// has the fewest overflow characters and the lowest cost. If no solution fits,
/// we'll use this one.
///
/// As a final escape hatch for pathologically nasty code, after trying some
/// fixed maximum number of solve states, we just bail and return the best
/// solution found so far.
///
/// Even with the above algorithmic optimizations, complex code may still
/// require a lot of exploring to find an optimal solution. To make that fast,
/// this code is carefully profiled and optimized. If you modify this, make
/// sure to test against the benchmark to ensure you don't regress performance.
class LineSplitter {
  final LineWriter _writer;

  /// The list of chunks being split.
  final List<Chunk> _chunks;

  /// The set of soft rules whose values are being selected.
  final List<Rule> _rules;

  /// The number of characters of additional indentation to apply to each line.
  ///
  /// This is used when formatting blocks to get the output into the right
  /// column based on where the block appears.
  final int _blockIndentation;

  /// The starting column of the first line.
  final int _firstLineIndent;

  /// The list of solve states to explore further.
  ///
  /// This is sorted lowest-cost first. This ensures that as soon as we find a
  /// solution that fits in the page, we know it will be the lowest cost one
  /// and can stop looking.
  final _workList = new HeapPriorityQueue<SolveState>();

  /// The lowest cost solution found so far.
  SolveState _bestSolution;

  /// Creates a new splitter for [_writer] that tries to fit [chunks] into the
  /// page width.
  LineSplitter(this._writer, List<Chunk> chunks, int blockIndentation,
      int firstLineIndent,
      {bool flushLeft: false})
      : _chunks = chunks,
        // Collect the set of soft rules that we need to select values for.
        _rules = chunks
            .map((chunk) => chunk.rule)
            .where((rule) => rule != null && rule is! HardSplitRule)
            .toSet()
            .toList(growable: false),
        _blockIndentation = blockIndentation,
        _firstLineIndent = flushLeft ? 0 : firstLineIndent + blockIndentation {
    // Store the rule's index in the rule so we can get from a chunk to a rule
    // index quickly.
    for (var i = 0; i < _rules.length; i++) {
      _rules[i].index = i;
    }
  }

  /// Determine the best way to split the chunks into lines that fit in the
  /// page, if possible.
  ///
  /// Returns a [SplitSet] that defines where each split occurs and the
  /// indentation of each line.
  ///
  /// [firstLineIndent] is the number of characters of whitespace to prefix the
  /// first line of output with.
  SplitSet apply() {
    // Start with a completely unbound, unsplit solution.
    _workList.add(new SolveState(this, new RuleSet(_rules.length)));

    var attempts = 0;
    while (!_workList.isEmpty) {
      var state = _workList.removeFirst();

      if (state.isBetterThan(_bestSolution)) {
        _bestSolution = state;

        // Since we sort solutions by cost the first solution we find that
        // fits is the winner.
        if (_bestSolution.overflowChars == 0) break;
      }

      if (debug.traceSplitter) {
        var best = state == _bestSolution ? " (best)" : "";
        debug.log("$state$best");
        debug.dumpLines(_chunks, _firstLineIndent, state.splits);
        debug.log();
      }

      if (attempts++ > _maxAttempts) break;

      // Try bumping the rule values for rules whose chunks are on long lines.
      state.expand();
    }

    if (debug.traceSplitter) {
      debug.log("$_bestSolution (winner)");
      debug.dumpLines(_chunks, _firstLineIndent, _bestSolution.splits);
      debug.log();
    }

    return _bestSolution.splits;
  }
}

/// A possibly incomplete solution in the line splitting search space.
///
/// A single [SolveState] binds some subset of the rules to values while
/// leaving the rest unbound. If every rule is bound, the solve state describes
/// a complete solution to the line splitting problem. Even if rules are
/// unbound, a state can also usually be used as a solution by treating all
/// unbound rules as unsplit. (The usually is because a state that constrains
/// an unbound rule to split can't be used with that rule unsplit.)
///
/// From a given solve state, we can explore the search tree to more refined
/// solve states by producing new ones that add more bound rules to the current
/// state.
class SolveState implements Comparable<SolveState> {
  final LineSplitter _splitter;
  final RuleSet _ruleValues;

  /// The unbound rules in this state that can be bound to produce new more
  /// refined states.
  ///
  /// Keeping this set small is the key to make the entire line splitter
  /// perform well. If we consider too make rules at each state, our
  /// exploration of the solution space is too branchy and we waste time on
  /// dead end solutions.
  ///
  /// Here is the key insight. The line splitter treats any unbound rule as
  /// being unsplit. This means refining a solution always means taking a rule
  /// that is unsplit and making it split. That monotonically increases the
  /// cost, but may help fit the solution inside the page.
  ///
  /// We want to keep the cost low, so the only reason to consider making a
  /// rule split is if it reduces an overflowing line. It's also the case that
  /// splitting an earlier rule will often reshuffle the rest of the line.
  ///
  /// Taking that into account, the only rules we consider binding to extend a
  /// solve state are *unbound rules inside the first line that is overflowing*.
  /// Even if a line has dozens of rules, this generally keeps the branching
  /// down to a few. It also means rules inside lines that already fit are
  /// never touched.
  ///
  /// There is one other set of rules that go in here. Sometimes a bound rule
  /// in the solve state constrains some other unbound rule to split. In that
  /// case, we also consider that active so we know to not leave it at zero.
  final _liveRules = new Set<Rule>();

  /// The set of splits chosen for this state.
  SplitSet get splits => _splits;
  SplitSet _splits;

  /// The number of characters that do not fit inside the page with this set of
  /// splits.
  int get overflowChars => _overflowChars;
  int _overflowChars;

  /// Whether we can treat this state as a complete solution by leaving its
  /// unbound rules unsplit.
  ///
  /// This is generally true but will be false if the state contains any
  /// unbound rules that are constrained to not be zero by other bound rules.
  /// This avoids picking a solution that leaves those rules at zero when they
  /// aren't allowed to be.
  bool _isComplete = true;

  SolveState(this._splitter, this._ruleValues) {
    _calculateSplits();
    _calculateCost();
  }

  /// Orders this state relative to [other].
  ///
  /// This is the best-first ordering that the [LineSplitter] uses in its
  /// worklist. It prefers cheaper states even if they overflow because this
  /// ensures it finds the best solution first as soon as it finds one that
  /// fits in the page so it can early out.
  int compareTo(SolveState other) {
    // TODO(rnystrom): It may be worth sorting by the estimated lowest number
    // of overflow characters first. That doesn't help in cases where there is
    // a solution that fits, but may help in corner cases where there is no
    // fitting solution.

    if (splits.cost != other.splits.cost) {
      return splits.cost.compareTo(other.splits.cost);
    }

    if (overflowChars != other.overflowChars) {
      return overflowChars.compareTo(other.overflowChars);
    }

    // Distinguish states based on the rule values just so that states with the
    // same cost range but different rule values don't get considered identical
    // by HeapPriorityQueue.
    for (var rule in _splitter._rules) {
      var value = _ruleValues.getValue(rule);
      var otherValue = other._ruleValues.getValue(rule);

      if (value != otherValue) return value.compareTo(otherValue);
    }

    // If we get here, this state is identical to [other].
    return 0;
  }

  /// Returns `true` if this state is a better solution to use as the final
  /// result than [other].
  bool isBetterThan(SolveState other) {
    // If this state contains an unbound rule that we know can't be left
    // unsplit, we can't pick this as a solution.
    if (!_isComplete) return false;

    // Anything is better than nothing.
    if (other == null) return true;

    // Prefer the solution that fits the most in the page.
    if (overflowChars != other.overflowChars) {
      return overflowChars < other.overflowChars;
    }

    // Otherwise, prefer the best cost.
    return splits.cost < other.splits.cost;
  }

  /// Enqueues more solve states to consider based on this one.
  ///
  /// For each unbound rule in this state that occurred in the first long line,
  /// enqueue solve states that bind that rule to each value it can have and
  /// bind all previous rules to zero. (In other words, try all subsolutions
  /// where that rule becomes the first new rule to split at.)
  void expand() {
    var unsplitRules = _ruleValues.clone();

    // Walk down the rules looking for unbound ones to try.
    var triedRules = 0;
    for (var rule in _splitter._rules) {
      if (_liveRules.contains(rule)) {
        // We found one worth trying, so try all of its values.
        for (var value = 1; value < rule.numValues; value++) {
          var boundRules = unsplitRules.clone();

          var mustSplitRules;
          var valid = boundRules.tryBind(_splitter._rules, rule, value, (rule) {
            if (mustSplitRules == null) mustSplitRules = [];
            mustSplitRules.add(rule);
          });

          // Make sure we don't violate the constraints of the bound rules.
          if (!valid) continue;

          var state = new SolveState(_splitter, boundRules);

          // If some unbound rules are constrained to split, remember that.
          if (mustSplitRules != null) {
            state._isComplete = false;
            state._liveRules.addAll(mustSplitRules);
          }

          _splitter._workList.add(state);
        }

        // Stop once we've tried all of the ones we can.
        if (++triedRules == _liveRules.length) break;
      }

      // Fill in previous unbound rules with zero.
      if (!_ruleValues.contains(rule)) {
        // Pass a dummy callback because zero will never fail. (If it would
        // have, that rule would already be bound to some other value.)
        if (!unsplitRules.tryBind(_splitter._rules, rule, 0, (_) {})) {
          break;
        }
      }
    }
  }

  /// Calculates the [SplitSet] for this solve state, assuming any unbound
  /// rules are set to zero.
  void _calculateSplits() {
    // Figure out which expression nesting levels got split and need to be
    // assigned columns.
    var usedNestingLevels = new Set();
    for (var i = 0; i < _splitter._chunks.length - 1; i++) {
      var chunk = _splitter._chunks[i];
      if (chunk.rule.isSplit(_getValue(chunk.rule), chunk)) {
        usedNestingLevels.add(chunk.nesting);
        chunk.nesting.clearTotalUsedIndent();
      }
    }

    for (var nesting in usedNestingLevels) {
      nesting.refreshTotalUsedIndent(usedNestingLevels);
    }

    _splits = new SplitSet(_splitter._chunks.length);
    for (var i = 0; i < _splitter._chunks.length - 1; i++) {
      var chunk = _splitter._chunks[i];
      if (chunk.rule.isSplit(_getValue(chunk.rule), chunk)) {
        var indent = 0;
        if (!chunk.flushLeftAfter) {
          // Add in the chunk's indent.
          indent = _splitter._blockIndentation + chunk.indent;

          // And any expression nesting.
          indent += chunk.nesting.totalUsedIndent;
        }

        _splits.add(i, indent);
      }
    }
  }

  /// Gets the value to use for [rule], either the bound value or `0` if it
  /// isn't bound.
  int _getValue(Rule rule) {
    if (rule is HardSplitRule) return 0;

    return _ruleValues.getValue(rule);
  }

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of rules.
  void _calculateCost() {
    assert(_splits != null);

    // Calculate the length of each line and apply the cost of any spans that
    // get split.
    var cost = 0;
    _overflowChars = 0;

    var length = _splitter._firstLineIndent;

    // The unbound rules in use by the current line. This will be null after
    // the first long line has completed.
    var currentLineRules = [];

    endLine(int end) {
      // Track lines that went over the length. It is only rules contained in
      // long lines that we may want to split.
      if (length > _splitter._writer.pageWidth) {
        _overflowChars += length - _splitter._writer.pageWidth;

        // Only try rules that are in the first long line, since we know at
        // least one of them *will* be split.
        if (currentLineRules != null && currentLineRules.isNotEmpty) {
          _liveRules.addAll(currentLineRules);
          currentLineRules = null;
        }
      } else {
        // The line fit, so don't keep track of its rules.
        if (currentLineRules != null) {
          currentLineRules.clear();
        }
      }
    }

    // The set of spans that contain chunks that ended up splitting. We store
    // these in a set so a span's cost doesn't get double-counted if more than
    // one split occurs in it.
    var splitSpans = new Set();

    for (var i = 0; i < _splitter._chunks.length; i++) {
      var chunk = _splitter._chunks[i];

      length += chunk.text.length;

      // Ignore the split after the last chunk.
      if (i == _splitter._chunks.length - 1) break;

      if (_splits.shouldSplitAt(i)) {
        endLine(i);

        splitSpans.addAll(chunk.spans);

        // Include the cost of the nested block.
        if (chunk.blockChunks.isNotEmpty) {
          cost +=
              _splitter._writer.formatBlock(chunk, _splits.getColumn(i)).cost;
        }

        // Start the new line.
        length = _splits.getColumn(i);
      } else {
        if (chunk.spaceWhenUnsplit) length++;

        // Include the nested block inline, if any.
        length += chunk.unsplitBlockLength;

        // If we might be in the first overly long line, keep track of any
        // unbound rules we encounter. These are ones that we'll want to try to
        // bind to shorten the long line.
        if (currentLineRules != null &&
            chunk.rule != null &&
            !chunk.isHardSplit &&
            !_ruleValues.contains(chunk.rule)) {
          currentLineRules.add(chunk.rule);
        }
      }
    }

    // Add the costs for the rules that split.
    _ruleValues.forEach(_splitter._rules, (rule, value) {
      // A rule may be bound to zero if another rule constrains it to not split.
      if (value != 0) cost += rule.cost;
    });

    // Add the costs for the spans containing splits.
    for (var span in splitSpans) cost += span.cost;

    // Finish the last line.
    endLine(_splitter._chunks.length);

    _splits.setCost(cost);
  }

  String toString() {
    var buffer = new StringBuffer();

    buffer.writeAll(
        _splitter._rules.map((rule) {
          var valueLength = "${rule.fullySplitValue}".length;

          var value = "?";
          if (_ruleValues.contains(rule)) {
            value = "${_ruleValues.getValue(rule)}";
          }

          value = value.padLeft(valueLength);
          if (_liveRules.contains(rule)) {
            value = debug.bold(value);
          } else {
            value = debug.gray(value);
          }

          return value;
        }),
        " ");

    buffer.write("   \$${splits.cost}");

    if (overflowChars > 0) buffer.write(" (${overflowChars} over)");
    if (!_isComplete) buffer.write(" (incomplete)");
    if (splits == null) buffer.write(" invalid");

    return buffer.toString();
  }
}
