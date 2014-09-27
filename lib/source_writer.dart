// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.source_writer;

import 'line.dart';
import 'line_printer.dart';

class SourceWriter {
  final StringBuffer buffer = new StringBuffer();

  final String lineSeparator;

  /// The current indentation level.
  ///
  /// Subsequent lines will be created with this much leading indentation.
  int indent = 0;

  final LinePrinter printer;

  Line _currentLine;

  /// Gets the current [Line] being written.
  Line get currentLine {
    // Lazy initialize. This was we use the most up-to-date indentation when
    // creating the line.
    if (_currentLine == null) {
      _currentLine = new Line(indent: indent);
    }

    return _currentLine;
  }

  SourceWriter({this.indent: 0, this.lineSeparator: "\n", int pageWidth: 80})
      : printer = (pageWidth > 0) ? new LineBreaker(pageWidth)
                                  : new LinePrinter();

  /// Prints the current line and completes it.
  ///
  /// If no tokens have been written since the last line was ended, this still
  /// prints an empty line.
  void newline() {
    if (_currentLine != null) {
      buffer.writeln(printer.printLine(_currentLine));
    } else {
      buffer.writeln();
    }

    _currentLine = null;
  }

  // TODO(rnystrom): Get rid of this, or at least limit it. We don't want to
  // preserve all of the user's newlines.
  void newlines(int count) {
    while (count-- > 0) {
      newline();
    }
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// In most cases, this just appends it to the current line. However, if
  /// [string] is for a multi-line string, it will span multiple lines. In that
  /// case, this splits it into lines and handles each line separately.
  void write(String string) {
    var lines = string.split(lineSeparator);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      currentLine.addToken(new LineToken(line));
      if (i != lines.length - 1) {
        newline();

        // Do not indent multi-line strings since we are inside the middle of
        // the string literal itself.
        _currentLine = new Line(indent: 0);
      }
    }
  }

  void space() {
    spaces(1);
  }

  void spaces(n, {weight: Weight.normal}) {
    currentLine.addSpaces(n, weight: weight);
  }

  String toString() {
    var source = new StringBuffer(buffer.toString());

    if (_currentLine != null) {
      source.write(printer.printLine(_currentLine));
    }

    return source.toString();
  }

  void _startLine() {
    _currentLine = new Line(indent: indent);
  }
}
