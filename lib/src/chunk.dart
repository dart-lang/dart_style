// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.chunk;

import 'debug.dart';
import 'rule.dart';

/// Tracks where a selection start or end point may appear in some piece of
/// text.
abstract class Selection {
  /// The chunk of text.
  String get text;

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int get selectionStart => _selectionStart;
  int _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int get selectionEnd => _selectionEnd;
  int _selectionEnd;

  /// Sets [selectionStart] to be [start] characters into [text].
  void startSelection(int start) {
    _selectionStart = start;
  }

  /// Sets [selectionStart] to be [fromEnd] characters from the end of [text].
  void startSelectionFromEnd(int fromEnd) {
    _selectionStart = text.length - fromEnd;
  }

  /// Sets [selectionEnd] to be [end] characters into [text].
  void endSelection(int end) {
    _selectionEnd = end;
  }

  /// Sets [selectionEnd] to be [fromEnd] characters from the end of [text].
  void endSelectionFromEnd(int fromEnd) {
    _selectionEnd = text.length - fromEnd;
  }
}

// TODO(bob): Clean up docs that mention param.
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
class Chunk extends Selection {
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
  int nesting = -1;

  /// Whether or not the chunk occurs inside an expression.
  ///
  /// Splits within expressions must take into account how deeply nested they
  /// are to determine the indentation of subsequent lines. "Statement level"
  /// splits that occur between statements or in the top-level of a unit only
  /// take the main indent level into account.
  bool get isInExpression => nesting != -1;

  /// Whether it's valid to add more text to this chunk or not.
  ///
  /// Chunks are built up by adding text and then "capped off" by having their
  /// split information set by calling [handleSplit]. Once the latter has been
  /// called, no more text should be added to the chunk since it would appear
  /// *before* the split.
  bool get canAddText => _indent == null;

  /// The [SplitRule] that determines if this chunk is being used as a split
  /// or not.
  ///
  /// Multiple splits may share a [SplitRule].
  ///
  /// This is `null` for hard splits.
  Rule get rule => _rule;
  Rule _rule;
  // TODO(bob): Do we want to have an actual rule for hard splits?

  /// Whether this chunk is always followed by a newline or whether the line
  /// splitter may choose to keep the next chunk on the same line.
  bool get isHardSplit => _indent != null && _rule is HardSplitRule;

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

  /// The number of characters in this chunk when unsplit.
  int get length => _text.length + (spaceWhenUnsplit ? 1 : 0);

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
  /// This is called on the soft splits owned by a rule that decides to harden
  /// when it finds out another hard split occurs within its chunks.
  void harden() {
    _rule = new HardSplitRule();
  }

  // TODO(bob): Doc rule.
  /// Finishes off this chunk with the given split information.
  ///
  /// This may be called multiple times on the same split since the splits
  /// produced by walking the source and the splits coming from comments and
  /// preserved whitespace often overlap. When that happens, this has logic to
  /// combine that information into a single split.
  void applySplit(int indent, int nesting, Rule rule,
      {bool spaceWhenUnsplit, bool isDouble}) {
    if (spaceWhenUnsplit == null) spaceWhenUnsplit = false;
    if (isDouble == null) isDouble = false;

    // TODO(bob): Don't use type test here.
    if (isHardSplit || rule is HardSplitRule) {
      // A hard split always wins.
      _rule = rule;
    } else if (_indent == null) {
      // If the chunk hasn't been initialized yet, just inherit the rule.
      _rule = rule;
    }

    // Last newline settings win.
    _indent = indent;
    this.nesting = nesting;
    _spaceWhenUnsplit = spaceWhenUnsplit;

    // Preserve a blank line.
    _isDouble = _isDouble || isDouble;
  }

  String toString() {
    var parts = [];

    if (text.isNotEmpty) parts.add("${Color.bold}$text${Color.none}");

    if (_indent != 0 && _indent != null) parts.add("indent:$_indent");
    if (nesting != -1) parts.add("nest:$nesting");
    if (spaceWhenUnsplit) parts.add("space");
    if (_isDouble) parts.add("double");

    if (_indent == null) {
      parts.add("(no split info)");
    } else if (!isHardSplit) {
      parts.add(rule.toString());
    }

    return parts.join(" ");
  }
}

/// Constants for the cost heuristics used to determine which set of splits is
/// most desirable.
class Cost {
  /// The smallest cost.
  ///
  /// This isn't zero because we want to ensure all splitting has *some* cost,
  /// otherwise, the formatter won't try to keep things on one line at all.
  /// Almost all splits and spans use this. Greater costs tend to come from a
  /// greater number of nested spans.
  static const normal = 1;

  /// Splitting after a "=" both for assignment and initialization.
  static const assignment = 2;

  /// Splitting before the first argument when it happens to be a function
  /// expression with a block body.
  static const firstBlockArgument = 2;

  /// The series of positional arguments.
  static const positionalArguments = 2;

  /// Splitting inside the brackets of a list with only one element.
  static const singleElementList = 2;

  /// The cost of a single character that goes past the page limit.
  ///
  /// This cost is high to ensure any solution that fits in the page is
  /// preferred over one that does not.
  static const overflowChar = 1000;
}

/// Delimits a range of chunks that must end up on the same line to avoid an
/// additional cost.
///
/// These are used to encourage the line splitter to try to keep things
/// together, like parameter lists and binary operator expressions.
class Span {
  /// Index of the first chunk contained in this span.
  int get start => _start;
  int _start;

  /// Index of the last chunk contained in this span.
  int get end => _end;
  int _end;

  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  Span(this._start, this.cost);

  /// Marks this span as ending at [end].
  void close(int end) {
    assert(_end == null);
    _end = end;
  }

  String toString() {
    var result = "Span($start";

    if (end != null) {
      result += " - $end";
    } else {
      result += "...";
    }

    if (cost != null) result += " \$$cost";

    return result + ")";
  }

  /// This is used when a prefix of the chunk list gets pulled off by the
  /// [LineWriter] and is formatted as a line. The remaining spans need to have
  /// their indices shifted to account for the removed chunks.
  ///
  /// Returns `true` if the span is contained in the prefix being removed and
  /// should be discarded.
  bool subtractPrefix(int offset) {
    if (_start < offset) return true;

    _start -= offset;
    if (_end != null) _end -= offset;

    return false;
  }
}

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
class SourceComment extends Selection {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  final String text;

  /// The number of newlines between the comment or token preceding this comment
  /// and the beginning of this one.
  ///
  /// Will be zero if the comment is a trailing one.
  final int linesBefore;

  /// Whether this comment is a line comment.
  final bool isLineComment;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool isStartOfLine;

  SourceComment(this.text, this.linesBefore,
      {this.isLineComment, this.isStartOfLine});
}
