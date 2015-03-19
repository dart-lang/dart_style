// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitter;

import 'dart:math' as math;

import 'chunk.dart';
import 'debug.dart';
import 'line_prefix.dart';

/// The number of spaces in a single level of indentation.
const spacesPerIndent = 2;

/// The number of indentation levels in a single level of expression nesting.
const indentsPerNest = 2;

/// Cost or indent value used to indication no solution could be found.
const invalidSplits = -1;

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

  /// The set of spans that wrap around [_chunks].
  final List<Span> _spans;

  /// The leading indentation at the beginning of the first line.
  final int _indent;

  /// Memoization table for the best set of splits for the remainder of the
  /// line following a given prefix.
  final _bestSplits = <LinePrefix, SplitSet>{};

  /// Creates a new splitter that tries to fit a series of chunks within a
  /// given page width.
  LineSplitter(this._lineEnding, this._pageWidth, this._chunks, this._spans,
      this._indent) {
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
    var nestingDepth = _flattenNestingLevels();

    // Hack. The formatter doesn't handle formatting very deeply nested code
    // well. It can make performance spiral into a pit of sadness. Fortunately,
    // we only tend to see expressions pathologically deeply nested in
    // generated code that isn't read by humans much anyway. To avoid burning
    // too much time on these, harden any splits containing more than a certain
    // level of nesting.
    //
    // The number here was chosen empirically based on formatting the repo. It
    // was picked to get the best performance while affecting the minimum amount
    // of results.
    // TODO(rnystrom): Do something smarter.
    // TODO(bob): Had to crank this way down to get decent perf with new rule
    // stuff. Optimize or fix.
    const maxDepth = 5; // Was 9.
    if (nestingDepth > maxDepth) {
      for (var chunk in _chunks) {
        if (!chunk.isHardSplit && nestingDepth - chunk.nesting > maxDepth) {
          chunk.harden();
        }
      }
    }

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

        // Should have a valid set of splits when we get here.
        assert(indent != invalidSplits);
      } else {
        if (chunk.spaceWhenUnsplit) buffer.write(" ");
      }
    }

    return selection;
  }

  /// Removes any unused nesting levels from the chunks.
  ///
  /// The line splitter considers every possible combination of mapping
  /// indentation to nesting levels when trying to find the best solution. For
  /// example, it may assign 4 spaces of indentation to level 1, 8 spaces to
  /// level 3, etc.
  ///
  /// It's fairly common for a nesting level to not actually appear at the
  /// boundary of a chunk. The source visitor may enter more than one level of
  /// nesting at a point where a split cannot happen. In that case, there's no
  /// point in trying to assign an indentation level to that nesting level. It
  /// will never be used because no line will begin at that level of
  /// indentation.
  ///
  /// Worse, if the splitter *does* consider these levels, it can dramatically
  /// increase solving time. To avoid that, this renumbers all of the nesting
  /// levels in the chunks to not have any of these unused gaps.
  ///
  /// Returns the number of distinct nesting levels remaining after flattening.
  /// This may be zero if the chunks have no nesting (i.e. just statement-level
  /// indentation).
  int _flattenNestingLevels() {
    var nestingLevels = _chunks
        .map((chunk) => chunk.nesting)
        .where((nesting) => nesting != -1)
        .toSet()
        .toList();
    nestingLevels.sort();

    var nestingMap = {-1: -1};
    for (var i = 0; i < nestingLevels.length; i++) {
      nestingMap[nestingLevels[i]] = i;
    }

    for (var chunk in _chunks) {
      chunk.nesting = nestingMap[chunk.nesting];
    }

    return nestingLevels.length;
  }

  /// Finds the best set of splits to apply to the remainder of the line
  /// following [prefix].
  SplitSet _findBestSplits(LinePrefix prefix) {
    // Use the memoized result if we have it.
    if (_bestSplits.containsKey(prefix)) return _bestSplits[prefix];

    // We never need to split at the end of the last chunk.
    if (prefix.length == _chunks.length - 1) {
      return _bestSplits[prefix] = new SplitSet();
    }

    var chunk = _chunks[prefix.length];
    var bestSplits = new BestSplits();

    // See if this chunk's rule already has a value.
    var value = prefix.ruleValues[chunk.rule];
    if (value == null) {
      // No, so try every value for the rule.
      for (var value = 0; value < chunk.rule.numValues; value++) {
        _findBestSplitsForValue(prefix, bestSplits, value);
      }
    } else {
      // It does, so stick with it.
      _findBestSplitsForValue(prefix, bestSplits, value);
    }

    return _bestSplits[prefix] = bestSplits.splits;
  }

  /// Looks for sets of splits to apply to the suffix after [prefix], using
  /// [value] for the rule of the chunk just after the prefix.
  ///
  /// Updates [bestSplits] with candidate solutions that it finds.
  void _findBestSplitsForValue(
      LinePrefix prefix, BestSplits bestSplits, int value) {
    var chunk = _chunks[prefix.length];

    var isSplit = chunk.rule.isSplit(value, chunk);

    // If we're in a block that decided not to split, we can't allow any other
    // splits.
    if (isSplit && prefix.isInUnsplitBlock) return;

    // Create new prefixes including this chunk.
    if (!isSplit) {
      _tryLongerPrefix(prefix, bestSplits,
          prefix.advanceUnsplit(_chunks, value), isSplit);
    } else {
      // There can be multiple since there are different ways to handle a
      // jump in nesting depth.
      for (var longerPrefix in prefix.advanceSplit(_chunks, value)) {
        _tryLongerPrefix(prefix, bestSplits, longerPrefix, isSplit);
      }
    }
  }

  // TODO(bob): Doc.
  void _tryLongerPrefix(LinePrefix prefix, BestSplits bestSplits,
      LinePrefix longerPrefix, bool isSplit) {
    var remaining = _findBestSplits(longerPrefix);

    // If it wasn't possible to split the suffix given this nesting stack,
    // skip it.
    if (remaining == null) return;

    var splits = remaining;
    if (isSplit) {
      splits = remaining.add(prefix.length, longerPrefix.nestingIndent);
    }

    var indent = prefix.getNextLineIndent(_chunks, _indent);
    var cost = _evaluateCost(prefix, indent, splits);
    bestSplits.update(splits, cost);
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
    var splitIndexes = [];

    endLine() {
      // Punish lines that went over the length. We don't rule these out
      // completely because it may be that the only solution still goes over
      // (for example with long string literals).
      if (length > _pageWidth) {
        cost += (length - _pageWidth) * Cost.overflowChar;
      }
    }

    for (var i = prefix.length; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      length += chunk.text.length;

      if (i < _chunks.length - 1) {
        if (splits.shouldSplitAt(i)) {
          endLine();
          splitIndexes.add(i);

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

    // See which spans got split. We avoid iterators here for performance.
    for (var i = 0; i < _spans.length; i++) {
      var span = _spans[i];
      for (var j = 0; j < splitIndexes.length; j++) {
        var index = splitIndexes[j];

        // If the split is contained within a span (and is not the tail end of
        // it), the span got split.
        if (index >= span.start && index < span.end) {
          cost += span.cost;
          break;
        }
      }
    }

    // Finish the last line.
    endLine();

    return cost;
  }
}

/// Keeps track of the best set of splits found so far.
class BestSplits {
  SplitSet _bestSplits;
  int _lowestCost;

  /// The best set of splits currently found.
  SplitSet get splits => _bestSplits;

  /// Compares [splits] which has [cost] to the best set found so far and keeps
  /// it if it's better.
  void update(SplitSet splits, int cost) {
    // TODO(bob): Is weight still needed?
    if (_lowestCost == null ||
        cost < _lowestCost/* ||
        (cost == _lowestCost && splits.weight > _bestSplits.weight)*/) {
      _bestSplits = splits;
      _lowestCost = cost;
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
