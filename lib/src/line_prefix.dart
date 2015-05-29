// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_prefix;

import 'chunk.dart';
import 'nesting.dart';
import 'rule.dart';

/// The number of spaces in a single level of indentation.
const spacesPerIndent = 2;

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

  /// The stack of bodies that are open at the end of the prefix.
  final NestingStack _body;

  /// Additional indentation within the current [_body].
  ///
  /// This handles things like switch cases, blocks, and constructor
  /// initialization lists that tweak the per-line indentation but aren't full
  /// bodies themselves.
  final int _extraIndent;

  /// The current expression nesting at the end of the prefix.
  final NestingStack _nesting;

  /// The indentation level after this chunk, including expression nesting.
  int get indent => _body.indent + _extraIndent + _nesting.indent;

  /// The actual absolute starting column of the line after this chunk.
  ///
  /// Unlike [indent], this takes into account whether the line should be
  /// flush left or not. Also, returns a column number, not an indentation
  /// level count.
  int get column => _flushLeft ? 0 : indent * spacesPerIndent;
  final bool _flushLeft;

  /// Creates a new zero-length prefix with initial [indent] whose suffix is
  /// the entire line.
  LinePrefix(int indent)
      : this._(0, {}, new NestingStack(), indent, new NestingStack(),
          flushLeft: false);

  LinePrefix._(this.length, this.ruleValues, this._body, this._extraIndent,
      this._nesting, {bool flushLeft : false})
      : _flushLeft = flushLeft;

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_extraIndent != other._extraIndent) return false;
    if (_flushLeft != other._flushLeft) return false;
    if (_body != other._body) return false;
    if (_nesting != other._nesting) return false;

    // Compare rule values.
    if (ruleValues.length != other.ruleValues.length) return false;

    for (var key in ruleValues.keys) {
      if (other.ruleValues[key] != ruleValues[key]) return false;
    }

    return true;
  }

  // TODO(rnystrom): Can we make this more effective?
  int get hashCode =>
      length.hashCode ^
      _body.hashCode ^
      _extraIndent ^
      _nesting.hashCode;

  /// Create a new LinePrefix one chunk longer than this one using [ruleValues],
  /// and assuming that we do not split before that chunk.
  LinePrefix extend(Map<Rule, int> ruleValues) =>
      new LinePrefix._(length + 1, ruleValues, _body, _extraIndent, _nesting,
          flushLeft: _flushLeft);

  /// Create a series of new LinePrefixes one chunk longer than this one using
  /// [ruleValues], and assuming that the new [chunk] splits at an expression
  /// boundary so there may be multiple possible different nesting stacks.
  Iterable<LinePrefix> split(Chunk chunk, Map<Rule, int> updatedValues) {
    // TODO(rnystrom): Inline this in LineSplitter?
    var body = _body.updateBody(chunk.bodyDepth, indent);

    // TODO(bob): To ignore nesting, use _body.indent + _offset instead of chunk.indent.
    return _nesting.updateExpression(chunk.nesting)
        .map((nesting) => new LinePrefix._(
            length + 1, updatedValues, body, chunk.indent, nesting,
            flushLeft: chunk.flushLeft));
  }

  String toString() {
    var result = "prefix $length";
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
