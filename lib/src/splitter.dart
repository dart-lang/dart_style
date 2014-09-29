// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.splitter;

/// A wrapper around a bit of state -- whether or not a set of [SplitChunks]
/// are active of not.
///
/// Each [SplitChunk] has a reference to the [SplitState] that controls it.
/// When the state is active, all of the split chunks will be applied, which
/// may in turn output line-breaks, indentation, unindentation, etc.
abstract class SplitState {
  /// Whether or not this splitter is currently in effect.
  ///
  /// If `false`, then the splitter is not trying to do any line splitting. If
  /// `true`, it is.
  bool get isSplit;
}

/// An actively configurable [SplitState].
///
/// When [LinePrinter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of splitters to see which set of
/// active ones yields the best result.
///
/// Unlike [SplitState] which exposes only a read-only view of the current
/// state, this lets outside code (the line printer) actively modify the split
/// state.
class Splitter implements SplitState {
  bool isSplit = false;

  /// Returns `true` if this splitter is allowed to be split given that its
  /// splits mapped to [splitLines].
  ///
  /// This lets a splitter do validation *after* all other splits have been
  /// applied it. It allows things like list literals to base their splitting
  /// on how their contents ended up being split.
  bool isValidSplit(List<int> splitLines) => true;

  /// Returns `true` if this splitter is allowed to be unsplit given that its
  /// splits mapped to [splitLines].
  ///
  /// This lets a splitter do validation *after* all other splits have been
  /// applied it. It allows things like list literals to base their splitting
  /// on how their contents ended up being split.
  bool isValidUnsplit(List<int> splitLines) => true;
}

/// A [Splitter] for list literals.
class ListSplitter extends Splitter {
  // Ensures the list is always split into its multi-line form if its elements
  // do not all fit on one line.
  bool isValidUnsplit(List<int> splitLines) {
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

/// A [SplitState] whose state depends on others.
///
/// Unlike [Splitter], which can be manually configured, the state of this is
/// implicit. It maintains references to other splits states. If any of them
/// are split, then this one is too.
///
/// This is used, for example, in a parameter list to ensure that if any of
/// the parameters are wrapped then the whole list is indented.
class AnySplitState implements SplitState {
  final states = <SplitState>[];

  bool get isSplit => states.any((splitter) => splitter.isSplit);
}
