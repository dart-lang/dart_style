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

abstract class Chunk {
  String get text;

  String toString() => text;
}

class TextChunk extends Chunk {
  final String text;

  TextChunk(this.text);
}

class RuleChunk implements Chunk {
  String get text => "";

  /// The [SplitRule] that is applied to this chunk, if any.
  ///
  /// May be `null`.
  final SplitRule rule;

  String toString() => "";

  RuleChunk(this.rule);
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
  /// Whether this param is currently split or forced.
  bool get isSplit => _isForced || _isSplit;

  /// Sets the split state.
  ///
  /// If the split is already forced, this has no effect.
  set isSplit(bool value) => _isSplit = value;

  // TODO(rnystrom): Making these mutable makes the line splitting code hard to
  // reason about.
  bool _isSplit = false;

  /// Whether this param has been "forced" to be in its split state.
  ///
  /// This means the line-splits algorithm no longer has the opportunity to try
  /// toggling this on and off to find a good set of splits.
  ///
  /// This happens when a param explicitly spans multiple lines, usually from
  /// an expression containing a function expression with a block body. Once the
  /// block body forces a line break, the surrounding expression must go into
  /// its multi-line state.
  bool get isForced => _isForced;
  bool _isForced = false;

  /// The cost of applying this param.
  ///
  /// This will be [SplitCost.FREE] if the param is managed by some rule
  /// instead. It always returns [SplitCost.FREE] if the param is not currently
  /// split.
  int get cost => isSplit ? _cost : SplitCost.FREE;
  final int _cost;

  SplitParam([this._cost = 0]);

  /// Forcibly splits this param.
  void force() {
    _isForced = true;
  }
}

class SplitCost {
  /// The cost used to represent a hard constraint that has been violated.
  ///
  /// When a rule returns this, the set of splits is not allowed to be used at
  /// all.
  static const DISALLOW = -1;
  // TODO(bob): Handle this better.

  /// The best cost, meaning the rule has been fully satisfied.
  static const FREE = 0;

  /// The cost of splitting between adjacent string literals.
  static const ADJACENT_STRINGS = 1;

  /// The cost of splitting after a "=>".
  static const ARROW = 2;

  /// The cost of splitting after a "=".
  static const ASSIGNMENT = 3;

  /// Keeps all argument or parameters in a list together on one line by
  /// splitting before the leading "(".
  static const ARGUMENTS_TOGETHER = 4;

  /// Split arguments across multiple lines but keep at least one on the first
  /// line after the "(".
  static const WRAP_REMAINING_ARGUMENTS = 5;

  /// Split arguments across multiple lines including wrapping after the
  /// leading "(".
  static const WRAP_FIRST_ARGUMENT = 6;

  // TODO(bob): Doc. Different operators.
  static const BINARY_OPERATOR = 7;

  /// The cost of a single character that goes past the page limit.
  static const OVERFLOW_CHAR = 1000;
}

/// A heuristic for evaluating how desirable a set of splits is.
///
/// Each instance of this inserts two or more [RuleChunk]s in the [Line]. When
/// a set of split is chosen, the line splitter determines which lines those
/// marks ended up in and tells the rule by calling [getCost()]. The rule then
/// determines how desirable that set of splits is.
abstract class SplitRule {
  /// Given that this rule's marks have ended up on [splitLines] after taking
  /// the current set of splits into effect, return this rule's "cost" -- how
  /// much it penalizes the resulting line splits.
  ///
  /// Returning a lower number here means that this rule is more satisfied and
  /// the resulting line is more likely to be a winner.
  int getCost(List<int> splitLines) => SplitCost.FREE;
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

  Multisplit(int cost)
    : param = new SplitParam(cost);
}

/// A [SplitRule] for argument and parameter lists.
class ArgumentListSplitRule extends SplitRule {
  int getCost(List<int> splitLines) {
    // If the line was force-split, we won't have all three marks so we can't
    // really evaluate this rule.
    // TODO(rnystrom): Do something better here?
    if (splitLines.length != 3) return SplitCost.FREE;

    var parenLine = splitLines[0];
    var firstArgLine = splitLines[1];
    var lastArgLine = splitLines[2];

    // The best is everything on one line.
    if (parenLine == lastArgLine) return SplitCost.FREE;

    // Next is keeping the args together by splitting after "(".
    if (firstArgLine == lastArgLine) return SplitCost.ARGUMENTS_TOGETHER;

    // If we can't do that, try to keep at least one argument on the "(" line.
    if (parenLine == firstArgLine) return SplitCost.WRAP_REMAINING_ARGUMENTS;

    return SplitCost.WRAP_FIRST_ARGUMENT;
  }
}
