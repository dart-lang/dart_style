// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../chunk.dart';
import '../nesting_level.dart';
import '../rule/rule.dart';
import 'line_splitter.dart';
import 'rule_set.dart';

/// Evaluates the cost (i.e. the relative "badness") of splitting a series of
/// chunks into lines using a given set of splits.
///
/// Calculcates the number of characters that exceed the page width, the overall
/// cost (including the cost of any nested blocks), and also the keeps track of
/// the "live rules" which appear before the first split.
class CostCalculator {
  final LineSplitter _splitter;
  final RuleSet _ruleValues;
  final SplitSet _splits;

  /// The set of rules that appear in the first line that doesn't fit in the
  /// page width, populated while calculating the cost.
  final Set<Rule> liveRules = {};

  int _cost = 0;

  /// The total number of overflow characters in all overflowing lines.
  int get overflowChars => _overflowChars;
  int _overflowChars = 0;

  /// The length of the current line being calculated.
  var _column = 0;

  /// The index of the first chunk in the current line.
  var _start = 0;

  /// Whether we have found a long line containing any unbound rules yet.
  ///
  /// We only split rules that aren't already bound, and that are used in lines
  /// that don't fit the page width. Also, we only split rules that appear in
  /// the *first* of these such lines, since any splitting choices made will
  /// affect subsequent lines anyway. This tracks whether we have found a line
  /// like this yet.
  var _foundOverflowRules = false;

  /// The set of spans that contain chunks that ended up splitting. We store
  /// these in a set so a span's cost doesn't get double-counted if more than
  /// one split occurs in it.
  final Set<Span> _splitSpans = {};

  CostCalculator(this._splitter, this._ruleValues, this._splits);

  /// Evaluates the cost (i.e. the relative "badness") of splitting the line
  /// into [lines] physical lines based on the current set of rules.
  void calculate() {
    // The nesting level of the chunk that ended the previous line.
    NestingLevel? previousNesting;

    // Write each chunk with the appropriate splits between them.
    for (var i = 0; i < _splitter.chunks.length; i++) {
      var chunk = _splitter.chunks[i];

      if (_splits.shouldSplitAt(i)) {
        // Add the costs for the spans containing splits.
        for (var span in chunk.spans) {
          if (_splitSpans.add(span)) _cost += span.cost;
        }

        // Do not allow sequential lines to have the same indentation but for
        // different reasons. In other words, don't allow different expressions
        // to claim the same nesting level on subsequent lines.
        //
        // A contrived example would be:
        //
        //     function(inner(
        //         argument), second(
        //         another);
        //
        // For the most part, we prevent this by the constraints on splits.
        // For example, the above can't happen because the split before
        // "argument", forces the split before "second".
        //
        // But there are a couple of squirrely cases where it's hard to prevent
        // by construction. Instead, this outlaws it by penalizing it very
        // heavily if it happens to get this far.
        var totalIndent = chunk.nesting.totalUsedIndent;
        if (previousNesting != null &&
            totalIndent != 0 &&
            totalIndent == previousNesting.totalUsedIndent &&
            !identical(chunk.nesting, previousNesting)) {
          _overflowChars += 10000;
        }

        previousNesting = chunk.nesting;

        // Start the new line.
        _endLine(i);
        _column = _splits.getColumn(i);
      } else {
        if (chunk.spaceWhenUnsplit) _column++;
      }

      // Write the block chunk's children first.
      if (chunk is BlockChunk) {
        if (_splits.shouldSplitAt(i)) {
          _traverseSplitBlock(chunk, _splits.getColumn(i));
        } else {
          // This block didn't split (which implies none of the child blocks
          // of that block split either, recursively), so write them all inline.
          _traverseUnsplitBlock(i, chunk, _splitter.blockIndentation);
        }
      }

      if (_splits.shouldSplitAt(i)) {
        _endLine(i);
        _column = _splits.getColumn(i);
      }

      _column += chunk.text.length;
    }

    // Add the costs for the rules that have any splits.
    _ruleValues.forEach(_splitter.rules, (rule, value) {
      if (value != Rule.unsplit) _cost += rule.cost;
    });

    // Finish the last line.
    _endLine(_splitter.chunks.length);

    // Store the final cost in the SplitSet.
    _splits.setCost(_cost);
  }

  void _traverseUnsplitBlock(int chunkIndex, BlockChunk block, int column) {
    for (var chunk in block.children) {
      if (chunk is BlockChunk && chunk.rule.isHardened) {
        // Even though the surrounding block didn't split, this chunk's
        // children did.
        _traverseSplitBlock(chunk, column + block.indent);
        _endLine(chunkIndex);

        _column = column + block.indent;
      } else {
        if (chunk.spaceWhenUnsplit) _column++;

        // Recurse into the block.
        if (chunk is BlockChunk) {
          _traverseUnsplitBlock(chunkIndex, chunk, column);
        }
      }

      _column += chunk.text.length;
    }
  }

  void _traverseSplitBlock(BlockChunk chunk, int column) {
    // Include the cost of the block.
    _cost += _splitter.writer.formatBlock(chunk, column).cost;
  }

  void _endLine(int end) {
    // Track lines that went over the length. It is only rules contained in
    // long lines that we may want to split.
    if (_column > _splitter.writer.pageWidth) {
      _overflowChars += _column - _splitter.writer.pageWidth;

      // Only try rules that are in the first long line, since we know at
      // least one of them *will* be split.
      if (!_foundOverflowRules) {
        for (var i = _start; i < end; i++) {
          if (_addLiveRules(_splitter.chunks[i].rule)) {
            _foundOverflowRules = true;
          }
        }
      }
    }

    _start = end;
  }

  /// Adds [rule] and all of the rules it constrains to the set of [_liveRules].
  ///
  /// Only does this if [rule] is a valid soft rule. Returns `true` if any new
  /// live rules were added.
  bool _addLiveRules(Rule? rule) {
    if (rule == null) return false;

    var added = false;
    for (var constrained in rule.allConstrainedRules) {
      if (_ruleValues.contains(constrained)) continue;

      liveRules.add(constrained);
      added = true;
    }

    return added;
  }
}