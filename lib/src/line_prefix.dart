// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_prefix;

import 'chunk.dart';
import 'nesting.dart';
import 'rule/rule.dart';

/// A prefix of a series of chunks and the context needed to uniquely describe
/// any shared state between the preceding and following chunks.
///
/// This is used by [LineSplitter] to memoize suffixes whose best splits have
/// previously been calculated. For each unique [LinePrefix], there is a single
/// set of best splits for the remainder of the line following it.
///
/// [LinePrefix] is a value type. It overloads [hashCode] and [==] and it's
/// critical that those be correct and efficient. These objects are used as
/// keys in the [LineSplitter]'s memoization table.
class LinePrefix {
  /// The number of chunks in the prefix.
  ///
  /// The suffix is the remaining chunks starting at index [length].
  final int length;

  /// The [Rule]s that apply to chunks in the prefix and have thus already had
  /// their values selected.
  ///
  /// Does not include rules that do not also appear in the suffix since they
  /// don't affect the suffix.
  final Map<Rule, int> ruleValues;

  /// The number of characters of "statement-based" indentation of the line
  /// after the prefix.
  ///
  /// This handles things like control flow, switch cases, and constructor
  /// initialization lists that tweak the per-line indentation.
  ///
  /// For nested blocks, this also includes the indentation to push the entire
  /// block over.
  final int _indent;

  final Nesting _nesting;

  /// The absolute starting column of the line after this chunk.
  ///
  /// This takes into account whether the line should be flush left or not.
  int get column => _flushLeft ? 0 : _indent + _nesting.indent;
  final bool _flushLeft;

  /// Creates a new zero-length prefix with initial [indent] whose suffix is
  /// the entire line.
  LinePrefix(int indent)
      : this._(0, {}, indent, new Nesting(), flushLeft: false);

  LinePrefix._(this.length, this.ruleValues, this._indent, this._nesting,
      {bool flushLeft : false})
      : _flushLeft = flushLeft;

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_indent != other._indent) return false;
    if (_flushLeft != other._flushLeft) return false;
    if (_nesting != other._nesting) return false;

    // Compare rule values.
    if (ruleValues.length != other.ruleValues.length) return false;

    for (var key in ruleValues.keys) {
      if (other.ruleValues[key] != ruleValues[key]) return false;
    }

    return true;
  }

  int get hashCode => length.hashCode ^ _indent ^ _nesting.hashCode;

  /// Create a new LinePrefix one chunk longer than this one using [ruleValues],
  /// and assuming that we do not split before that chunk.
  LinePrefix extend(Map<Rule, int> ruleValues) =>
      new LinePrefix._(length + 1, ruleValues, _indent, _nesting,
          flushLeft: _flushLeft);

  /// Create a series of new LinePrefixes one chunk longer than this one using
  /// [ruleValues], and assuming that the new [chunk] splits at an expression
  /// boundary so there may be multiple possible different nesting stacks.
  ///
  /// If this prefix is for a nested block, [blockIndentation] may be nonzero
  /// to push the output to the right.
  Iterable<LinePrefix> split(Chunk chunk, int blockIndentation,
      Map<Rule, int> ruleValues) {
    var indent = chunk.indent + blockIndentation;
    return _nesting.update(chunk.nesting).map((nesting) => new LinePrefix._(
        length + 1, ruleValues, indent, nesting, flushLeft: chunk.flushLeft));
  }

  String toString() {
    var result = "prefix $length";
    if (_indent != 0) result += " indent ${_indent}";
    if (_nesting.indent != 0) result += " nesting ${_nesting.indent}";
    if (ruleValues.isNotEmpty) {
      var rules = ruleValues.keys
          .map((key) => "$key:${ruleValues[key]}")
          .join(" ");

      result += " rules $rules";
    }
    return result;
  }
}
