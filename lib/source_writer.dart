// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.source_writer;

import 'line.dart';
import 'line_printer.dart';

class SourceWriter {
  final StringBuffer buffer = new StringBuffer();
  Line currentLine;

  final String lineSeparator;
  int indentCount = 0;

  LinePrinter linePrinter;
  LineToken _lastToken;

  SourceWriter({this.indentCount: 0, this.lineSeparator: "\n",
      int maxLineLength: 80}) {
    if (maxLineLength > 0) {
      linePrinter = new LineBreaker(maxLineLength);
    } else {
      linePrinter = new LinePrinter();
    }
    currentLine = newLine();
  }

  LineToken get lastToken => _lastToken;

  void indent() {
    indentCount++;

    // Rather than fiddle with deletions/insertions just start fresh.
    if (currentLine.isWhitespace()) {
      currentLine = newLine();
    }
  }

  void newline() {
    if (currentLine.isWhitespace()) {
      currentLine.tokens.clear();
    }
    _addToken(new NewlineToken(this.lineSeparator));

    buffer.write(linePrinter.printLine(currentLine));
    currentLine = newLine();
  }

  void newlines(int count) {
    while (count-- > 0) {
      newline();
    }
  }

  void write(String string) {
    var lines = string.split(lineSeparator);
    var length = lines.length;
    for (var i = 0; i < length; i++) {
      var line = lines[i];
      _addToken(new LineToken(line));
      if (i != length - 1) {
        newline();
        // No indentation for multi-line strings.
        currentLine.clear();
      }
    }
  }

  void space() {
    spaces(1);
  }

  void spaces(n, {weight: Weight.normal}) {
    currentLine.addSpaces(n, weight: weight);
  }

  void unindent() {
    --indentCount;

    // Rather than fiddle with deletions/insertions just start fresh.
    if (currentLine.isWhitespace()) currentLine = newLine();
  }

  Line newLine() => new Line(indentLevel: indentCount);

  String toString() {
    var source = new StringBuffer(buffer.toString());
    if (!currentLine.isWhitespace()) {
      source.write(linePrinter.printLine(currentLine));
    }
    return source.toString();
  }

  void _addToken(LineToken token) {
    _lastToken = token;
    currentLine.addToken(token);
  }
}
