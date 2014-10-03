// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

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

  /// Forcibly splits this param.
  void force() {
    _isForced = true;
  }
}

/// A strategy for splitting a line into one more separate lines.
///
/// Each instance of this controls one or more [SplitChunk]s in the [Line] and
/// exposes one or parameters that can be used to determine if they split or
/// not.
///
/// A splitter is also responsible for influencing how "good" a given set of
/// split states is. The line printer weighs the influences of all of the
/// splitters on the line to see how good a given set of choices is.
abstract class SplitRule {
  /// Returns `true` if this splitter's current parameters are valid given that
  /// its splits mapped to [splitLines].
  ///
  /// This lets a splitter do validation *after* all other splits have been
  /// applied. It allows things like list literals to base their splitting on
  /// how their contents ended up being split.
  bool isValid(List<int> splitLines) => true;
}

/// A [Splitter] for list and map literals.
class CollectionSplitRule extends SplitRule {
  /// The [SplitParam] for the collection.
  ///
  /// Since a collection will either be all on one line, or fully split into
  /// separate lines for each item and the brackets, only a single parameter
  /// is needed.
  final param = new SplitParam();

  // Ensures the list is always split into its multi-line form if its elements
  // do not all fit on one line.
  bool isValid(List<int> splitLines) {
    // Splitting is always allowed.
    if (param.isSplit) return true;

    // TODO(rnystrom): Do we want to allow single-element lists to remain
    // unsplit if their contents split, like:
    //
    //     [[
    //       first,
    //       second
    //     ]]

    var line = splitLines.first;
    return splitLines.every((other) => other == line);
  }
}
