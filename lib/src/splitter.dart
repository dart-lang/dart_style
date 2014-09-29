// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.splitter;

/// A splitter controls line-breaking in a [Line].
///
/// Each splitter owns one or more [SplitChunk]s. A given splitter can be active
/// or inactive. When active, all of its split chunks will be applied, which
/// may in turn output line-breaks, indentation, unindentation, etc.
///
/// When [LinePrinter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of splitters to see which set of
/// active ones yields the best result.
class Splitter {
  /// Whether or not this splitter is currently in effect.
  ///
  /// If `false`, then the splitter is not trying to do any line splitting. If
  /// `true`, it is.
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
  bool isValidUnsplit(List<int> splitLines) {
    // TODO(rnystrom): Do we want to allow single-element lists to remain
    // unsplit if their contents split, like:
    //
    //     [[
    //       first,
    //       second
    //     ]]

    // It must split if the elements span multiple lines.
    var line = splitLines.first;
    return splitLines.every((other) => other == line);
  }
}