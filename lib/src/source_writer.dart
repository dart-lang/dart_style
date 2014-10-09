// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'line.dart';
import 'line_printer.dart';
import 'splitter.dart';

class SourceWriter {
  final buffer = new StringBuffer();

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
    if (_currentLine == null) _startLine();

    return _currentLine;
  }

  /// Keep track of which rules are currently being written.
  ///
  /// A rule depends on multiple [SplitChunk]s. If those end up being forcibly
  /// broken across multiple lines because a mandatory line break (such as
  /// after a `;` or `{`) occurs in the middle of a rule, they need to know
  /// this.
  ///
  /// For example, a collection can either be single line:
  ///
  ///    [all, on, one, line];
  ///
  /// or multi-line:
  ///
  ///    [
  ///      one,
  ///      item,
  ///      per,
  ///      line
  ///    ]
  ///
  /// Collections can also contain function expressions, which have blocks which
  /// in turn force a newline in the middle of the collection. When that
  /// happens, we need to force all surrounding collections to be multi-line.
  /// This tracks rules like that so we can do that.
  final _rules = <SplitRule>[];

  SourceWriter({this.indent: 0, this.lineSeparator: "\n", int pageWidth: 80})
      : printer = new LinePrinter(pageWidth: pageWidth);

  /// Prints the current line and completes it.
  ///
  /// If no tokens have been written since the last line was ended, this still
  /// prints an empty line.
  void newline() {
    if (_currentLine != null) {
      // TODO(rnystrom): I'm still not really happy with how this is handled.
      // Is there a more elegant solution?
      // If we are in the middle of rules that might need splitting, we know
      // they are definitely going to be multi-line now.
      for (var rules in _rules) {
        rules.forceSplit();
      }

      buffer.writeln(printer.printLine(_currentLine));
    } else {
      buffer.writeln();
    }

    _currentLine = null;
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
      currentLine.write(line);
      if (i != lines.length - 1) {
        newline();

        // Do not indent multi-line strings since we are inside the middle of
        // the string literal itself.
        _currentLine = new Line(indent: 0);
      }
    }
  }

  /// Begin a new rule that is in play for the current line.
  ///
  /// This also implicitly creates a starting mark for the rule. When the rule
  /// is done, call [endRule()] to remove it.
  void startRule(SplitRule rule) {
    _rules.add(rule);
    ruleMark();
  }

  /// End the current innermost rule.
  ///
  /// Implicity adds an ending mark to the current line.
  void endRule() {
    ruleMark();
    _rules.removeLast();
  }

  /// Add a mark at the current position in the current line for the current
  /// innermost rule.
  void ruleMark() {
    currentLine.chunks.add(new RuleChunk(_rules.last));
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
