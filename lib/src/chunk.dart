// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.chunk;

import 'cost.dart';
import 'debug.dart';

/// A chunk of non-breaking output text terminated by a hard or soft newline.
///
/// Chunks are created by [LineWriter] and fed into [LineSplitter]. Each
/// contains some text, along with the data needed to tell how the next line
/// should be formatted and how desireable it is to split after the chunk.
///
/// Line splitting after chunks comes in a few different forms.
///
/// *   A "hard" split is a mandatory newline. The formatted output will contain
///     at least one newline after the chunk's text.
/// *   A "soft" split is a discretionary newline. If a line doesn't fit within
///     the page width, one or more soft splits may be turned into newlines to
///     wrap the line to fit within the bounds. If a soft split is not turned
///     into a newline, it may instead appear as a space or zero-length string
///     in the output, depending on [spaceWhenUnsplit].
/// *   A "double" split expands to two newlines. In other words, it leaves a
///     blank line in the output. Hard or soft splits may be doubled. This is
///     determined by [isDouble].
///
/// A split controls the leading spacing of the subsequent line, both
/// block-based [indent] and expression-wrapping-based [nesting].
class Chunk {
  /// The literal text output for the chunk.
  String get text => _text;
  String _text;

  /// The indentation level of the line following this chunk.
  ///
  /// Note that this is not a relative indentation *offset*. It's the full
  /// indentation. When a chunk is newly created from text, this is `null` to
  /// indicate that the chunk has no splitting information yet.
  int get indent => _indent;
  int _indent = null;

  /// The number of levels of expression nesting following this chunk.
  ///
  /// This is used to determine how much to increase the indentation when a
  /// line starts after this chunk. A single statement may be indented multiple
  /// times if the splits occur in more deeply nested expressions, for example:
  ///
  ///     // 40 columns                           |
  ///     someFunctionName(argument, argument,
  ///         argument, anotherFunction(argument,
  ///             argument));
  int get nesting => _nesting;
  int _nesting = -1;

  /// Whether or not the chunk occurs inside an expression.
  ///
  /// Splits within expressions must take into account how deeply nested they
  /// are to determine the indentation of subsequent lines. "Statement level"
  /// splits that occur between statements or in the top-level of a unit only
  /// take the main indent level into account.
  bool get isInExpression => _nesting != -1;

  /// Whether it's valid to add more text to this chunk or not.
  ///
  /// Chunks are built up by adding text and then "capped off" by having their
  /// split information set by calling [handleSplit]. Once the latter has been
  /// called, no more text should be added to the chunk since it would appear
  /// *before* the split.
  bool get canAddText => _indent == null;

  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
  ///
  /// Multiple splits may share a [SplitParam] because they are part of the
  /// same [Multisplit], in which case they are split or unsplit in unison.
  ///
  /// This is `null` for hard splits.
  SplitParam get param => _param;
  SplitParam _param;

  /// Whether this chunk is always followed by a newline or whether the line
  /// splitter may choose to keep the next chunk on the same line.
  bool get isHardSplit => _indent != null && _param == null;

  /// Whether this chunk may cause a newline depending on line splitting.
  bool get isSoftSplit => _indent != null && _param != null;

  /// `true` if an extra blank line should be output after this chunk if it's
  /// split.
  bool get isDouble => _isDouble;
  bool _isDouble = false;

  /// Whether this chunk should append an extra space if it's a soft split and
  /// is left unsplit.
  ///
  /// This is `true`, for example, in a chunk that ends with a ",".
  bool get spaceWhenUnsplit => _spaceWhenUnsplit;
  bool _spaceWhenUnsplit = false;

  /// Creates a new chunk starting with [_text].
  Chunk(this._text);

  /// Discard the split for the chunk and put it back into the state where more
  /// text can be appended.
  void allowText() {
    _indent = null;
  }

  /// Append [text] to the end of the split's text.
  void appendText(String text) {
    assert(canAddText);

    _text += text;
  }

  /// Forces this soft split to become a hard split.
  ///
  /// This is called on the soft splits of a [Multisplit] when it ends up
  /// containing some other hard split.
  void harden() {
    assert(_param != null);
    _param = null;
  }

  /// Finishes off this chunk with the given split information.
  ///
  /// This may be called multiple times on the same split since the splits
  /// produced by walking the source and the splits coming from comments and
  /// preserved whitespace often overlap. When that happens, this has logic to
  /// combine that information into a single split.
  void applySplit(int indent, int nesting, SplitParam param,
      {bool spaceWhenUnsplit, bool isDouble}) {
    if (spaceWhenUnsplit == null) spaceWhenUnsplit = false;
    if (isDouble == null) isDouble = false;

    if (isHardSplit || param == null) {
      // A hard split always wins.
      _param = null;
    } else if (_indent == null) {
      // If the chunk hasn't been initialized yet, just inherit the param.
      _param = param;
    }

    // Last newline settings win.
    _indent = indent;
    _nesting = nesting;
    _spaceWhenUnsplit = spaceWhenUnsplit;

    // Preserve a blank line.
    _isDouble = _isDouble || isDouble;
  }

  String toString() {
    var parts = [];

    if (text.isNotEmpty) parts.add("${Color.bold}$text${Color.none}");

    if (_indent == null) {
      parts.add("(no split info)");
    } else if (isHardSplit) {
      parts.add("hard");
    } else {
      parts.add("p$_param");
    }

    if (_indent != 0) parts.add("indent:$_indent");
    if (_nesting != -1) parts.add("nest:$_nesting");
    if (spaceWhenUnsplit) parts.add("space");
    if (_isDouble) parts.add("double");

    return parts.join(" ");
  }
}

/// Controls whether or not one or more soft split [Chunk]s are split.
///
/// When [LineSplitter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of parameters to see which set of
/// active ones yields the best result.
class SplitParam {
  /// The cost of this param when split.
  final int cost;

  /// Creates a new [SplitParam].
  SplitParam([this.cost = Cost.CHEAP]);

  String toString() => "$cost";
}

/// Delimits a range of chunks that must end up on the same line to avoid a
/// penalty.
///
/// Spans come in two flavors. Simple cost spans just increase the cost of the
/// resulting solution if their contents don't fit inside a line. These are used
/// to encourage the line splitter to try to keep things together, like
/// parameter lists and binary operator expressions.
///
/// Multisplit spans are associates with the [SplitParam] for a [Multisplit].
/// When a multisplit gets broken across multiple lines -- even if due to a
/// split not owned by the multisplit -- the multisplit must itself be split.
/// Make sure any unsplit multisplits don't get split across multiple
/// lines. For example:
///
///     [() {
///       body;
///     }]
///
/// The above code is mis-formatted. The hard newline inside the function
/// should force the outer multisplit for the list to also split, leading to:
///
///     [
///       () {
///         body;
///       }
///     ]
///
/// To enforce this, every multisplit creates a [Span] bound to its param and
/// covering the same region of chunks as the multisplit itself. When the line
/// splitter chooses a solution, if this span is broken but the underlying
/// param has not been set, then it considers that a failed solution.
class Span {
  /// The param for the [Multisplit] this span manages, or `null` if the span
  /// is not bound to a multisplit.
  SplitParam get param => _param;
  SplitParam _param;

  /// Index of the first chunk contained in this span.
  final int start;

  /// Index of the last chunk contained in this span.
  int get end => _end;
  int _end;

  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  Span(this.start, this.cost)
      : _param = null;

  Span.multisplit(this.start, this._param)
      : cost = null;

  /// Marks this span as ending at [end].
  void close(int end) {
    assert(_end == null);
    _end = end;
  }

  /// Updates this span's [param] to [to] if it is [from].
  void rebindParam(SplitParam from, SplitParam to) {
    if (_param == from) _param = to;
  }

  String toString() {
    var result = "Span($start";

    if (end != null) {
      result += " - $end";
    } else {
      result += "...";
    }

    if (cost != null) result += " \$$cost";
    if (_param != null) result += " p$_param";

    return result + ")";
  }
}
