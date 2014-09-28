// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.writer;

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final List<LineToken> tokens = <LineToken>[];

  /// The number of levels of indentation at the beginning of this line.
  int indent;

  /// Returns `true` if the line contains no visible text.
  bool get isEmpty => tokens.isEmpty;

  Line({this.indent: 0});

  void addSpace(SpaceToken space) {
    // Should not add leading whitespace.
    assert(tokens.isNotEmpty);

    // Should not have back-to-back spaces.
    assert(tokens.isEmpty || tokens.last is! SpaceToken);

    tokens.add(space);
  }

  /// Add [text] to the end of the current line.
  ///
  /// This will append to the end of the last token if the last token is also
  /// text. Otherwise, it creates a new token.
  void write(String text) {
    if (tokens.isEmpty || tokens.last is SpaceToken) {
      tokens.add(new LineToken(text));
    } else {
      tokens[tokens.length - 1] = new LineToken(tokens.last.value + text);
    }
  }

  void clearIndentation() {
    assert(tokens.isEmpty);
    indent = 0;
  }
}

/// A working piece of text used in calculating line breaks.
class Chunk {
  final int indent;
  final List<LineToken> tokens = <LineToken>[];

  /// Gets the indentation before this chunk as a string of whitespace.
  String get indentString => " " * (indent * SPACES_PER_INDENT);

  Chunk(this.indent, [List<LineToken> tokens]) {
    this.tokens.addAll(tokens);
  }

  /// The combined length of all tokens in this chunk.
  int get length => tokens.fold(indent * SPACES_PER_INDENT,
      (len, token) => len + token.length);

  /// Whether this chunk contains any spaces.
  bool get hasAnySpace => tokens.any((token) => token is SpaceToken);

  void add(LineToken token) {
    tokens.add(token);
  }

  Chunk subChunk(int indentLevel, int start, [int end]) {
    List<LineToken> subTokens = tokens.sublist(start, end);
    return new Chunk(indentLevel, subTokens);
  }

  String toString() => tokens.join();
}

class LineToken {
  final String value;

  /// The number of characters in the token's [value].
  int get length => value.length;

  LineToken(this.value);

  String toString() => value;
}

class SpaceToken extends LineToken {
  SpaceToken({bool zeroWidth: false}) : super(zeroWidth ? "" : " ");
}
