// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line;

import 'splitter.dart';

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
