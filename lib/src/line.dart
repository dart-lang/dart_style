// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line;

import 'debug.dart';

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final chunks = <Chunk>[];

  /// The number of levels of indentation at the beginning of this line.
  int indent;

  Line({this.indent: 0});

  /// Add [text] to the end of the current line.
  void write(String text) {
    chunks.add(new TextChunk(text));
  }
}

class Chunk {
  // TODO(bob): This should only exist on chunks that make it to splitting.
  String get text => throw "should not get here!";
}

// TODO(bob): Separate out chunk types that should make it to the line splitter
// from those that should be processed by the writer beforehand?

class TextChunk extends Chunk {
  final String text;

  TextChunk(this.text);

  String toString() {
    var visibleWhitespace = text.replaceAll(
        " ", "${Color.gray}·${Color.noColor}");
    return "${Color.bold}$visibleWhitespace${Color.none}";
  }
}

class SpaceChunk extends Chunk {
  String get text => " ";

  String toString() => "${Color.gray}(space)${Color.none}";
}

/// The kind of pending whitespace that has been "written", but not actually
/// physically output yet.
///
/// We defer actually writing whitespace until a non-whitespace token is
/// encountered to avoid trailing whitespace.
class Whitespace {
  /// A single newline.
  static const NEWLINE = const Whitespace._("NEWLINE");

  /// Two newlines, a single blank line of separation.
  static const TWO_NEWLINES = const Whitespace._("TWO_NEWLINES");

  /// A space or newline should be output based on whether the current token is
  /// on the same line as the previous one or not.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const SPACE_OR_NEWLINE = const Whitespace._("SPACE_OR_NEWLINE");

  /// One or two newlines should be output based on how many newlines are
  /// present between the next token and the previous one.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const ONE_OR_TWO_NEWLINES = const Whitespace._("ONE_OR_TWO_NEWLINES");

  final String name;

  const Whitespace._(this.name);

  String toString() => name;
}

// TODO(bob): Extend LineChunk?
class WhitespaceChunk extends Chunk {
  // TODO(bob): Make final?
  Whitespace type;

  // TODO(bob): Make final?
  int indent;

  // TODO(bob): Do something better.
  int actual = 0;

  final int nesting;

  WhitespaceChunk(this.type, this.indent, this.nesting);

  String toString() {
    var result = type.toString().toLowerCase();
    if (indent != 0) result += " indent $indent";
    if (nesting != 0) result += " nest $nesting";
    if (actual != 0) result += " actual $actual";
    return result;
  }
}

// TODO(bob): Doc.
// TODO(bob): Extend LineChunk?
class CommentChunk extends Chunk {
  final String text;

  /// The indentation level of lines after this line comment.
  final int indent;

  /// The number of levels of expression nesting that this comment occurs
  /// within.
  final int nesting;

  final bool isLineComment;
  bool get isBlockComment => !isLineComment;

  /// `true` if there is non-whitespace source text on the same line before this
  /// comment. For example:
  ///
  ///     someTextBefore; // a comment
  bool isTrailing;

  /// `true` if there is non-whitespace source text on the same line after this
  /// comment. For example:
  ///
  ///     /* a comment */ someTextAfter;
  final bool isLeading;

  /// `true` if this comment has non-whitespace text both before and after it.
  bool get isInline => isTrailing && isLeading;

  CommentChunk(this.text, this.indent, this.nesting,
      {this.isLineComment, this.isTrailing, this.isLeading});

  String toString() {
    var result = "${Color.gray}$text${Color.none}";
    if (indent != 0) result += " indent $indent";
    if (nesting != 0) result += " nest $nesting";
    if (isTrailing) result += " trailing";
    if (isLeading) result += " leading";
    return result;
  }
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

// TODO(bob): Doc.
class IndentChunk extends Chunk {
  // TODO(bob): Yet more copy/paste indent/nesting.
  final int indent;
  final int nesting;

  IndentChunk(this.indent, this.nesting);

  String toString() {
    var result = "${Color.cyan}->${Color.none}";
    if (indent != 0) result += " indent $indent";
    if (nesting != 0) result += " nest $nesting";
    return result;
  }
}

class UnindentChunk extends Chunk {
  // TODO(bob): Yet more copy/paste indent/nesting.
  final int indent;
  final int nesting;

  // TODO(bob): Can we do something cleaner here? Seems like unindent shouldn't
  // care about this.
  /// Whether this unindent starts a newline.
  final bool newline;

  UnindentChunk(this.indent, this.nesting, {this.newline});

  String toString() {
    var result = "${Color.cyan}<-${Color.none}";
    if (indent != 0) result += " indent $indent";
    if (nesting != 0) result += " nest $nesting";
    return result;
  }
}

// TODO(bob): Update other docs that refer to old SplitChunk.
// TODO(bob): Doc.
abstract class SplitChunk extends Chunk {
  /// The indentation level of the next line after this one.
  ///
  /// Note that this is not a relative indentation *offset*. It's the full
  /// indentation.
  final int indent;

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
  final int nesting;

  SplitChunk(this.indent, this.nesting);
}

// TODO(bob): Doc.
class HardSplitChunk extends SplitChunk {
  HardSplitChunk(int indent, int nesting) : super(indent, nesting);

  String toString() => "HardSplit indent $indent nest $nesting";
}

/// A split chunk that may expand to a newline (with some leading indentation)
/// or some other inline string based on the length of the line.
class SoftSplitChunk extends SplitChunk {
  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
  final SplitParam param;

  /// The text for this chunk when it's not split into a newline.
  final String text;

  SoftSplitChunk(int indent, int nesting, this.param, [this.text = ""])
      : super(indent, nesting);

  String toString() =>
      "SoftSplit \$$param indent $indent nest $nesting '$text'";
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
  SplitParam([this.cost = SplitCost.FREE]);

  String toString() => "$cost";
}

class SplitCost {
  /// The best cost, meaning the rule has been fully satisfied.
  static const FREE = 0;

  static const BEFORE_EXTENDS = 3;
  static const BEFORE_IMPLEMENTS = 2;
  static const BEFORE_WITH = 1;

  // TODO(rnystrom): Is this correct? Should it be greater for longer
  // collections?
  /// Splitting a list or map literal.
  static const COLLECTION_LITERAL = 1;

  /// After each variable in a variable declaration list.
  static const DECLARATION = 1;

  /// Between adjacent string literals.
  static const ADJACENT_STRINGS = 10;

  /// Splitting before "." in a method call.
  static const BEFORE_PERIOD = 20;

  /// After a "=>".
  static const ARROW = 20;

  /// The cost of failing to keep all arguments on one line.
  ///
  /// This is in addition to the cost of splitting after any specific argument.
  static const SPLIT_ARGUMENTS = 20;

  /// After the ":" in a conditional expression.
  static const AFTER_COLON = 20;

  /// The cost of splitting before any argument (including the first) in an
  /// argument list.
  ///
  /// Successive arguments decrement from here so that it prefers to split over
  /// later arguments.
  static const BEFORE_ARGUMENT = 30;

  /// After the "?" in a conditional expression.
  static const AFTER_CONDITION = 30;

  /// After a "=" both for assignment and initialization.
  static const ASSIGNMENT = 40;

  // TODO(rnystrom): Different costs for different operators.
  /// The cost of splitting after a binary operator.
  static const BINARY_OPERATOR = 80;

  /// The cost of a single character that goes past the page limit.
  static const OVERFLOW_CHAR = 10000;
}

/// Handles a series of [SoftSplitChunks] that all either split or don't split
/// together.
///
/// This is used for:
///
/// * Map and list literals.
/// * A series of the same binary operator.
/// * A series of chained method calls.
///
/// In all of these, either the entire expression will be a single line, or it
/// will be fully split into multiple lines, with no intermediate states
/// allowed.
///
/// There is still the question of how a multisplit handles an explicit newline
/// (usually from a function literal subexpression) contained within the
/// multisplit. There are two variations: separable and inseparable. Most are
/// the latter.
///
/// An inseparable multisplit treats a hard newline as forcing the entire
/// multisplit to split, like so:
///
///     [
///       () {
///         // This forces the list to be split.
///       }
///     ]
///
/// A separable one breaks the multisplit into two independent multisplits, each
/// of which may or may not be split based on its own range. For example:
///
///     compiler
///         .somethingLong()
///         .somethingLong()
///         .somethingLong((_) {
///       // The calls above this split because they are long.
///     }).a().b();
///     The trailing calls are short enough to not split.
class Multisplit {
  /// The [SplitParam] that controls all of the split chunks.
  SplitParam get param => _param;
  SplitParam _param;

  /// `true` if a hard newline has forced this multisplit to be split.
  ///
  /// Initially `false`.
  bool get isSplit => _isSplit;
  bool _isSplit = false;

  final bool _separable;

  Multisplit(int cost, {bool separable})
      : _param = new SplitParam(cost),
        _separable = separable != null ? separable : false;

  /// Handles a newline occurring in the middle of this multisplit.
  ///
  /// If the multisplit is separable, this creates a new param so the previous
  /// split chunks can vary independently of later ones. Otherwise, it just
  /// marks this multisplit as being split.
  void split() {
    if (_separable) {
      _param = new SplitParam(param.cost);
    } else {
      _isSplit = true;
    }
  }
}
