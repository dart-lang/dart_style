// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'chunk.dart';
import 'nesting.dart';

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

  /// The [SplitParam]s for params that appear both in the prefix and suffix
  /// and have not been set.
  ///
  /// This is used to ensure that we honor the decisions already made in the
  /// prefix when processing the suffix. It only includes params that appear in
  /// the suffix to avoid storing information about irrelevant params. This is
  /// critical to ensure we keep prefixes simple to maximize the reuse we get
  /// from the memoization table.
  ///
  /// This does *not* include params that appear only in the suffix. In other
  /// words, it only includes params that have deliberately been chosen to not
  /// be set, not params we simply haven't considered yet.
  final Set<SplitParam> unsplitParams;

  /// The [SplitParam]s for params that appear both in the prefix and suffix
  /// and have been set.
  ///
  /// This is used to ensure that we honor the decisions already made in the
  /// prefix when processing the suffix. It only includes params that appear in
  /// the suffix to avoid storing information about irrelevant params. This is
  /// critical to ensure we keep prefixes simple to maximize the reuse we get
  /// from the memoization table.
  final Set<SplitParam> splitParams;

  /// The nested expressions in the prefix that are still open at the beginning
  /// of the suffix.
  ///
  /// For example, if the line is `outer(inner(argument))`, and the prefix is
  /// `outer(inner(`, the nesting stack will be two levels deep.
  final NestingStack _nesting;

  /// The depth of indentation caused expression nesting.
  int get nestingIndent => _nesting.indent;

  /// Creates a new zero-length prefix whose suffix is the entire line.
  LinePrefix([int length = 0])
      : this._(length, new Set(), new Set(), new NestingStack());

  LinePrefix._(this.length, this.unsplitParams, this.splitParams,
      this._nesting) {
    assert(_nesting != null);
  }

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_nesting != other._nesting) return false;

    if (unsplitParams.length != other.unsplitParams.length) {
      return false;
    }

    if (splitParams.length != other.splitParams.length) {
      return false;
    }

    for (var param in unsplitParams) {
      if (!other.unsplitParams.contains(param)) return false;
    }

    for (var param in splitParams) {
      if (!other.splitParams.contains(param)) return false;
    }

    return true;
  }

  int get hashCode => length.hashCode ^ _nesting.hashCode;

  /// Create zero or more new [LinePrefix]es starting from the same nesting
  /// stack as this one but expanded to [length].
  ///
  /// The nesting of the chunk immediately preceding the suffix modifies the
  /// new prefix's nesting stack.
  ///
  /// [unsplitParams] is the set of [SplitParam]s in the new prefix that the
  /// splitter decided to *not* split (including unsplit ones also in this
  /// prefix). [splitParams] is likewise the set that have been chosen to be
  /// split.
  ///
  /// Returns an empty iterable if the new split chunk results in an invalid
  /// prefix. See [NestingStack.applySplit] for details.
  Iterable<LinePrefix> expand(List<Chunk> chunks, Set<SplitParam> unsplitParams,
      Set<SplitParam> splitParams, int length) {
    var split = chunks[length - 1];

    if (!split.isInExpression) {
      return [
        new LinePrefix._(length, unsplitParams, splitParams,
            new NestingStack())
      ];
    }

    return _nesting.applySplit(split).map((nesting) =>
        new LinePrefix._(
            length, unsplitParams, splitParams, nesting));
  }

  /// Gets the leading indentation of the newline that immediately follows
  /// this prefix.
  ///
  /// Takes into account the indentation of the previous split and any
  /// additional indentation from wrapped nested expressions.
  int getNextLineIndent(List<Chunk> chunks, int indent) {
    // TODO(rnystrom): This could be cached at construction time, which may be
    // faster.
    // Get the initial indentation of the line immediately after the prefix,
    // ignoring any extra indentation caused by nested expressions.
    if (length > 0) {
      indent = chunks[length - 1].indent;
    }

    return indent + _nesting.indent;
  }

  String toString() =>
      "LinePrefix(length $length, nesting $_nesting, "
      "unsplit $unsplitParams, split $splitParams)";
}
