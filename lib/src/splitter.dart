// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(rnystrom): Rename library.
library dart_style.src.splitter;

import 'line.dart';

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
  static const ADJACENT_STRINGS = 1000;

  /// The cost of splitting after a "=>".
  static const ARROW = 2000;

  /// The cost of splitting after a "=".
  static const ASSIGNMENT = 3000;

  /// Keeps all argument or parameters in a list together on one line by
  /// splitting before the leading "(".
  static const ARGUMENTS_TOGETHER = 4000;

  /// Split arguments across multiple lines but keep at least one on the first
  /// line after the "(".
  static const WRAP_REMAINING_ARGUMENTS = 5000;

  /// Split arguments across multiple lines including wrapping after the
  /// leading "(".
  static const WRAP_FIRST_ARGUMENT = 6000;

  // TODO(bob): Doc. Different operators.
  static const BINARY_OPERATOR = 7000;

  /// The cost of a single character that goes past the page limit.
  static const OVERFLOW_CHAR = 1000000;
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

  /// This is called if a hard line break occurs while the rule is still in
  /// effect. Override this to determine how that affects the rule.
  void forceSplit() {}
}

/// A [SplitRule] for a series of [SplitChunks] that all either split or don't
/// split together.
///
/// This is used for list and map literals, and for a series of the same binary
/// operator. In all of these, either the entire expression will be a single
/// line, or it will be fully split into multiple lines, with not intermediate
/// states allowed.
class AllSplitRule extends SplitRule {
  /// The [SplitParam] for the collection.
  ///
  /// Since a collection will either be all on one line, or fully split into
  /// separate lines for each item and the brackets, only a single parameter
  /// is needed.
  final SplitParam param;

  AllSplitRule([int cost = SplitCost.FREE])
    : param = new SplitParam(cost);

  // Ensures the list is always split into its multi-line form if its elements
  // do not all fit on one line.
  int getCost(List<int> splitLines) {
    // Splitting is always allowed.
    if (param.isSplit) return param.cost;

    // TODO(rnystrom): Do we want to allow single-element lists to remain
    // unsplit if their contents split, like:
    //
    //     [[
    //       first,
    //       second
    //     ]]

    return splitLines.first == splitLines.last ?
        SplitCost.FREE : SplitCost.DISALLOW;
  }

  void forceSplit() {
    param.force();
  }
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
