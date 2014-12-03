// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line;

import 'debug.dart';

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

/// The number of indentation levels in a single level of expression nesting.
const INDENTS_PER_NEST = 2;

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

abstract class Chunk {
  String get text;

  bool get isHardSplit => false;
  bool get isSoftSplit => false;
}

class TextChunk extends Chunk {
  final String text;

  TextChunk(this.text);

  String toString() {
    var visibleWhitespace = text.replaceAll(
        " ", "${Color.gray}·${Color.noColor}");
    return "${Color.bold}$visibleWhitespace${Color.none}";
  }
}

/// The kind of pending whitespace that has been "written", but not actually
/// physically output yet.
///
/// We defer actually writing whitespace until a non-whitespace token is
/// encountered to avoid trailing whitespace.
class Whitespace {
  /// A single non-breaking space.
  static const SPACE = const Whitespace._("SPACE");

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

/// The first of a pair of chunks used to delimit a range of chunks that must
/// end up on the same line to avoid paying a cost.
///
/// If a start and its paired end chunk end up split onto different lines, then
/// a cost penalty (in addition to the costs of the splits themselves) is added.
/// This is used to penalize splitting arguments onto multiple lines so that it
/// prefers to keep arguments together even if it means moving them all to the
/// next line when possible.
class SpanStartChunk extends Chunk {
  String get text => "";

  String toString() => "${Color.cyan}‹${Color.none}";
}

/// The second of a pair of chunks used to delimit a range of chunks that must
/// end up on the same line to avoid paying a cost.
///
/// See [SpanStartChunk] for details.
class SpanEndChunk extends Chunk {
  /// The [SpanStartChunk] that marks the beginning of this span.
  final SpanStartChunk start;

  /// The cost applied when the span is split across multiple lines.
  final int cost;

  String get text => "";

  SpanEndChunk(this.start, this.cost);

  String toString() => "${Color.cyan}›$cost${Color.none}";
}

// TODO(bob): Update other docs that refer to old SplitChunk.
// TODO(bob): Doc.
class SplitChunk extends Chunk {
  /// The text for this chunk when it's not split into a newline.
  final String text;

  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
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

  /// Creates a new [SplitChunk] where the following line will have [_indent]
  /// and [_nesting].
  ///
  /// If [_param] is non-`null`, creates a soft split. Otherwise, creates a
  /// hard split. When non-split, a soft split expands to [text].
  SplitChunk(this._indent, this._nesting, [this._param, this.text = ""]);

  bool get isHardSplit => _param == null;
  bool get isSoftSplit => _param != null;

  /// Returns `true` if this split is active, given that [splits] are all in
  /// effect.
  bool shouldSplit(Set<SplitParam> splits) =>
      _param == null || splits.contains(_param);

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

// TODO(bob): Move. Private to LineWriter. Sublibrary?
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
  /// The index of the first chunk contained by the multisplit.
  ///
  /// This is used to determine which chunk range needs to be scanned to look
  /// for hard newlines to see if the multisplit gets forced.
  final int startChunk;

  /// The [SplitParam] that controls all of the split chunks.
  SplitParam get param => _param;
  SplitParam _param;

  final bool _separable;

  Multisplit(this.startChunk, int cost, {bool separable})
      : _param = new SplitParam(cost),
        _separable = separable != null ? separable : false;
}
