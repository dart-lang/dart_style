// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.chunk;

import 'cost.dart';
import 'debug.dart';

// TODO(rnystrom): Now that TextChunks are coalesced, SplitChunks are merged,
// and spans are no longer chunks, a line is now a *strict* alternation of
// TextChunks and SplitChunks. Consider unifying those by adding "preceding
// text" to SplitChunk and turning it into just "Chunk".

/// A chunk of output.
///
/// Chunks are the input to the [LineSplitter]. They are either literal text
/// ([TextChunk]) or a piece of metadata used to determine how the series of
/// chunks should be best split into physical lines ([SplitChunk],
/// [SpanStartChunk], and [SpanEndChunk]).
///
/// These classes all implement [toString()] but only for debugging purposes.
abstract class Chunk {
  String get text;

  /// Whether this chunk is a [SplitChunk].
  bool get isSplit => false;

  /// Whether this chunk is a [SplitChunk] that must cause a newline.
  bool get isHardSplit => false;

  /// Whether this chunk is a [SplitChunk] that may cause a newline depending
  /// on how line-splitting goes.
  bool get isSoftSplit => false;
}

/// A string of literal program text or comment. This will end up in the final
/// formatted output verbatim.
class TextChunk extends Chunk {
  final String text;

  TextChunk(this.text);

  String toString() {
    var visibleWhitespace = text.replaceAll(
        " ", "${Color.gray}$UNICODE_MIDDOT${Color.noColor}");
    return "${Color.bold}$visibleWhitespace${Color.none}";
  }
}

/// A place where a line-break may appear in the final output.
///
/// Splits come in a few different forms:
///
/// *   A "hard" split is a mandatory newline. The formatted output will contain
///     at least one newline at this point.
/// *   A "soft" split is a discretionary newline. If a line doesn't fit within
///     the page width, one or more soft splits may be turned into newlines to
///     wrap the line to fit within the bounds. If a soft split is not turned
///     into a newline, it may instead appear as a space or zero-length string
///     in the output, depending on the split.
/// *   A "double" split expands to two newlines. In other words, it leaves a
///     blank line in the output. Hard or soft splits may be doubled.
///
/// A split controls the leading spacing of the subsequent line, both
/// block-based indentation and expression-wrapping-based nesting.
class SplitChunk extends Chunk {
  /// The text for this chunk when it's not split into a newline.
  final String text;

  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
  ///
  /// Multiple splits may share a [SplitParam] because they are part of the
  /// same [Multisplit], in which case the are split or unsplit in unison.
  ///
  /// This will be `null` for hard splits.
  SplitParam get param => _param;
  SplitParam _param;

  /// The indentation level of the next line after this one.
  ///
  /// Note that this is not a relative indentation *offset*. It's the full
  /// indentation.
  int get indent => _indent;
  int _indent;

  /// The number of levels of expression nesting at the end of this line.
  ///
  /// This is used to determine how much to increase the indentation when this
  /// split comes into effect. A single statement may be indented multiple
  /// times if the splits occur in more deeply nested expressions, for example:
  ///
  ///     // 40 columns                           |
  ///     someFunctionName(argument, argument,
  ///         argument, anotherFunction(argument,
  ///             argument));
  int get nesting => _nesting;
  int _nesting;

  /// Whether or not the split occurs inside an expression.
  ///
  /// Splits within expressions must take into account how deeply nested they
  /// are to determine the indentation of subsequent lines. "Statement level"
  /// splits that occur between statements or in the top-level of a unit only
  /// take the main indent level into account.
  bool get isInExpression => _nesting != -1;

  /// `true` if the split should output an extra blank line.
  bool get isDouble => _isDouble;
  bool _isDouble;

  /// Creates a new [SplitChunk] where the following line will have [_indent]
  /// and [_nesting].
  ///
  /// If [_param] is non-`null`, creates a soft split. Otherwise, creates a
  /// hard split. When non-split, a soft split expands to [text].
  SplitChunk(this._indent, this._nesting,
      {SplitParam param, this.text: "", bool double: false})
      : _param = param,
        _isDouble = double;

  bool get isSplit => true;
  bool get isHardSplit => _param == null;
  bool get isSoftSplit => _param != null;

  /// Merges [later] onto this split.
  ///
  /// This is called when redundant splits are written to the output. This is
  /// called on the first splitting, passing in the latter. It modifies this
  /// one to be a split containing the important properties of both.
  void mergeSplit(SplitChunk later) {
    // A hard split always wins.
    if (isHardSplit || later.isHardSplit) {
      _param = null;
    }

    // Last newline settings win.
    _indent = later._indent;
    _nesting = later._nesting;

    // Preserve a blank line.
    _isDouble = _isDouble || later._isDouble;

    // Text should either be irrelevant, or the same. We don't expect to merge
    // sequential soft splits with different text.
    assert(isHardSplit || text == later.text);
  }

  /// Forces this soft split to become a hard split.
  ///
  /// This is called on the soft splits of a [Multisplit] when it ends up
  /// containing some other hard split.
  void harden() {
    assert(_param != null);
    _param = null;
  }

  String toString() {
    var buffer = new StringBuffer();
    buffer.write("Split");
    if (_param != null) {
      buffer.write(" $_param");
    } else {
      buffer.write(" hard");
    }

    if (_isDouble) buffer.write(" double");
    if (_indent != 0) buffer.write(" indent $_indent");
    if (_nesting != -1) buffer.write(" nest $_nesting");
    if (text != "") buffer.write(" '$text'");

    return buffer.toString();
  }
}

/// A toggle for enabling one or more [SplitChunk]s in a [Line].
///
/// When [LinePrinter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of parameters to see which set of
/// active ones yields the best result.
class SplitParam {
  /// The cost of this param when split.
  final int cost;

  /// Creates a new [SplitParam].
  ///
  /// This should not be called directly from outside of [SourceWriter].
  SplitParam([this.cost = Cost.CHEAP]);

  String toString() => "$cost";
}

/// Delimits a range of chunks that must end up on the same line to avoid
/// paying a cost.
class Span {
  /// Index of the first chunk contained in this span.
  final int start;

  /// Index of the last chunk contained in this span.
  int get end => _end;
  int _end;

  /// The cost applied when the span is split across multiple lines.
  final int cost;

  Span(this.start, this.cost);

  void close(int end) {
    assert(_end == null);
    _end = end;
  }

  String toString() => "Span($start - $end \$$cost)";
}
