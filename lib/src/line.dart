// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line;

import 'splitter.dart';

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final chunks = <Chunk>[];

  bool get hasSplits => chunks.any((chunk) => chunk is SplitChunk);

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

/// A split chunk may expand to a newline (with some leading indentation) or
/// some other inline string based on the length of the line.
///
/// Each split chunk is owned by splitter that determines when it is and is
/// not in effect.
class SplitChunk extends Chunk {
  /// The [SplitParam] that determines if this chunk is being used as a split
  /// or not.
  final SplitParam param;

  /// The [SplitRule] that is applied to this chunk, if any.
  ///
  /// May be `null`.
  final SplitRule rule;

  /// The text for this chunk when it's not split into a newline.
  final String text;

  /// The indentation level of lines after this split.
  ///
  /// Note that this is not a relative indentation *offset*. It's the full
  /// indentation.
  final int indent;

  SplitChunk(this.indent, {SplitParam param, this.text: ""})
      : param = param != null ? param : new SplitParam(),
        rule = null;

  SplitChunk.forRule(this.rule, this.indent, {SplitParam param, this.text: ""})
      : param = param != null ? param : new SplitParam();
}
