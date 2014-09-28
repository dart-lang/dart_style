// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.writer;

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final List<String> tokens = [];

  /// The number of levels of indentation at the beginning of this line.
  int indent;

  /// Returns `true` if the line contains no visible text.
  bool get isEmpty => tokens.isEmpty;

  Line({this.indent: 0});

  /// Add [text] to the end of the current line.
  ///
  /// This will append to the end of the last token if the last token is also
  /// text. Otherwise, it creates a new token.
  void write(String text) {
    if (tokens.isEmpty) {
      tokens.add(text);
    } else {
      tokens[tokens.length - 1] = tokens.last + text;
    }
  }

  void clearIndentation() {
    assert(tokens.isEmpty);
    indent = 0;
  }
}
