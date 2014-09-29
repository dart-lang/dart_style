// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(rnystrom): Rename and move into src.
library dart_style.line;

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final chunks = <Chunk>[];
  final splitters = new Set<Splitter>();

  /// The number of levels of indentation at the beginning of this line.
  int indent;

  /// Returns `true` if the line contains no visible text.
  bool get isEmpty => chunks.isEmpty;

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

  void split(SplitChunk split) {
    chunks.add(split);
    splitters.add(split.splitter);
  }

  void clearIndentation() {
    assert(chunks.isEmpty);
    indent = 0;
  }
}

abstract class Chunk {
  String get text;
}

class TextChunk implements Chunk {
  final String text;

  TextChunk(this.text);

  String toString() => text;
}

/// A split chunk may expand to a newline (with some leading indentation) or
/// some other inline string based on the length of the line.
///
/// Each split chunk is owned by splitter that determines when it is and is
/// not in effect.
class SplitChunk implements Chunk {
  final Splitter splitter;

  /// The text for this chunk when it's not split into a newline.
  final String text;

  /// The amount of indentation this split increases or decreases subsequent
  /// lines.
  final int indent;

  /// If this split should become a newline when applied.
  ///
  /// Line continuations that are double-indented (like a normal wrapped
  /// expression) have a hanging unindent with no closing text after them.
  bool get isNewline => indent != -2;

  SplitChunk(this.splitter, this.text, this.indent);

  String toString() => splitter.isSplit ? "\n" : text;
}

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