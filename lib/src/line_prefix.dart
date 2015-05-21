// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_prefix;

import 'chunk.dart';
import 'nesting.dart';
import 'rule.dart';

/// A prefix of a series of chunks, which in turn can be considered a key to
/// describe the suffix of the remaining chunks that follows it.
///
/// This is used by the splitter to memoize suffixes whose best splits have
/// previously been calculated. For each unique [LinePrefix], there will be a
/// single set of best splits for the remainder of the line following it.
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

  /// The nested expressions in the prefix that are still open at the beginning
  /// of the suffix.
  ///
  /// For example, if the line is `outer(inner(argument))`, and the prefix is
  /// `outer(inner(`, the nesting stack will be two levels deep.
  final NestingStack _nesting;

  /// The indentation level of the line starting after this chunk, not
  /// including additional levels from [_nesting].
  final int _indent;

  /// The indentation level of the line starting after this chunk, including
  /// from expression nesting.
  int get indent => _indent + _nesting.indent;

  /// Creates a new zero-length prefix with initial [indent] whose suffix is
  /// the entire line.
  LinePrefix(int indent) : this._(0, {}, indent, new NestingStack());

  LinePrefix._(this.length, this.ruleValues, this._indent, this._nesting);

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_nesting != other._nesting) return false;

    // Compare rule values.
    if (ruleValues.length != other.ruleValues.length) return false;

    for (var key in ruleValues.keys) {
      if (other.ruleValues[key] != ruleValues[key]) return false;
    }

    return true;
  }

  // TODO(rnystrom): Can we make this more effective?
  int get hashCode => length.hashCode ^ _nesting.hashCode;

  /// Create a new LinePrefix one chunk longer than this one using [ruleValues],
  /// and assuming that we do not split before that chunk.
  LinePrefix extend(Map<Rule, int> ruleValues) =>
      new LinePrefix._(length + 1, ruleValues, _indent, _nesting);

  /// Create a series of new LinePrefixes one chunk longer than this one using
  /// [ruleValues], and assuming that the new [chunk] splits at an expression
  /// boundary so there may be multiple possible different nesting stacks.
  Iterable<LinePrefix> split(
      Chunk chunk, Map<Rule, int> updatedValues, int indent) {
    // TODO(rnystrom): Inline this in LineSplitter?
    return _nesting.applySplit(chunk).map((nesting) =>
        new LinePrefix._(length + 1, updatedValues, indent, nesting));
  }

  String toString() {
    var result = "prefix $length";
    if (_nesting.indent != 0) result += " nesting $_nesting";
    if (ruleValues.isNotEmpty) {
      var rules = ruleValues.keys
          .map((key) => "$key:${ruleValues[key]}")
          .join(" ");

      result += " rules $rules";
    }
    return result;
  }
}
