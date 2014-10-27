// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line;

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final chunks = <Chunk>[];

  bool get hasSplits => chunks.any((chunk) => chunk is SplitChunk);

  /// The number of levels of indentation at the beginning of this line.
  int indent;

  /// Gets the length of the line if no splits are taken into account.
  int get unsplitLength {
    var length = SPACES_PER_INDENT * indent;
    for (var chunk in chunks) {
      length += chunk.text.length;
    }

    return length;
  }

  Line({this.indent: 0});

  /// Add [text] to the end of the current line.
  ///
  /// This will append to the end of the last chunk if the last chunk is also
  /// text. Otherwise, it creates a new chunk.
  void write(String text) {
    if (chunks.isEmpty || chunks.last is! TextChunk) {
      chunks.add(new TextChunk(text));
    } else {
      var last = (chunks.last as TextChunk).text;
      chunks[chunks.length - 1] = new TextChunk(last + text);
    }
  }

  void clearIndentation() {
    assert(chunks.isEmpty);
    indent = 0;
  }
}

class Chunk {
  String get text => "";
  String toString() => text;
}

class TextChunk extends Chunk {
  final String text;

  TextChunk(this.text);
}

/// The first of a pair of chunks used to delimit a range of chunks that must
/// end up on the same line to avoid paying a cost.
///
/// If a start and its paired end chunk end up split onto different lines, then
/// a cost penalty (in addition to the costs of the splits themselves) is added.
/// This is used to penalize splitting arguments onto multiple lines so that it
/// prefers to keep arguments together even if it means moving them all to the
/// next line when possible.
class SpanStartChunk extends Chunk {}

/// The second of a pair of chunks used to delimit a range of chunks that must
/// end up on the same line to avoid paying a cost.
///
/// See [SpanStartChunk] for details.
class SpanEndChunk extends Chunk {
  /// The [SpanStartChunk] that marks the beginning of this span.
  final SpanStartChunk start;

  /// The cost applied when the span is split across multiple lines.
  final int cost;

  SpanEndChunk(this.start, this.cost);
}

/// A split chunk may expand to a newline (with some leading indentation) or
/// some other inline string based on the length of the line.
///
/// Each split chunk is owned by splitter that determines when it is and is
/// not in effect.
class SplitChunk extends Chunk {
  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
  final SplitParam param;

  /// The text for this chunk when it's not split into a newline.
  final String text;

  /// The indentation level of lines after this split.
  ///
  /// Note that this is not a relative indentation *offset*. It's the full
  /// indentation.
  final int indent;

  SplitChunk(this.indent, {SplitParam param, this.text: ""})
      : param = param != null ? param : new SplitParam();
}

/// A toggle for enabling one or more [SplitChunk]s in a [Line].
///
/// When [LinePrinter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of parameters to see which set of
/// active ones yields the best result.
class SplitParam {
  /// Whether this param is currently split or not.
  bool isSplit = false;

  /// The cost of this param when split.
  final int cost;

  SplitParam([this.cost = 0]);
}

class SplitCost {
  /// The best cost, meaning the rule has been fully satisfied.
  static const FREE = 0;

  static const BEFORE_EXTENDS = 3;
  static const BEFORE_IMPLEMENTS = 2;
  static const BEFORE_WITH = 1;

  /// Between adjacent string literals.
  static const ADJACENT_STRINGS = 10;

  /// After a "=>".
  static const ARROW = 20;

  /// After a "=" both for assignment and initialization.
  static const ASSIGNMENT = 30;

  /// The cost of splitting before any argument (including the first) in an
  /// argument list.
  ///
  /// Successive arguments decrement from here so that it prefers to split over
  /// later arguments.
  static const BEFORE_ARGUMENT = 20;

  /// The cost of failing to keep all arguments on one line.
  ///
  /// This is in addition to the cost of splitting after any specific argument.
  static const SPLIT_ARGUMENTS = 20;

  // TODO(rnystrom): Different costs for different operators.
  /// The cost of splitting after a binary operator.
  static const BINARY_OPERATOR = 80;

  /// The cost of a single character that goes past the page limit.
  static const OVERFLOW_CHAR = 10000;
}

/// Handles a series of [SplitChunks] that all either split or don't split
/// together.
///
/// This is used for list and map literals, and for a series of the same binary
/// operator. In all of these, either the entire expression will be a single
/// line, or it will be fully split into multiple lines, with no intermediate
/// states allowed.
class Multisplit {
  /// The [SplitParam] that controls all of the split chunks.
  final SplitParam param;

  /// `true` if a hard newline has forced this multisplit to be split.
  ///
  /// Initially `false`.
  bool isSplit = false;

  Multisplit(int cost)
    : param = new SplitParam(cost);
}
