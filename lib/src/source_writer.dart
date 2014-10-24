// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'line.dart';
import 'line_printer.dart';

class SourceWriter {
  final buffer = new StringBuffer();

  final String lineSeparator;

  /// The current indentation level.
  ///
  /// Subsequent lines will be created with this much leading indentation.
  int indent = 0;

  bool get isCurrentLineEmpty => _currentLine == null;

  final int _pageWidth;

  /// The line currently being written to, or `null` if a non-empty line has
  /// not been started yet.
  Line _currentLine;

  /// Keep track of which multisplits are currently being written.
  ///
  /// If a hard newline appears in the middle of a multisplit, then the
  /// multisplit itself must be split. For example, a collection can either be
  /// single line:
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
  /// This tracks them so we can do that.
  final _multisplits = <Multisplit>[];

  SourceWriter({this.indent: 0, this.lineSeparator: "\n", int pageWidth: 80})
      : _pageWidth = pageWidth;

  void clearIndentation() {
    _ensureLine();
    _currentLine.clearIndentation();
  }

  /// Prints the current line and completes it.
  ///
  /// If no tokens have been written since the last line was ended, this still
  /// prints an empty line.
  void newline() {
    if (_currentLine == null) {
      buffer.writeln();
      return;
    }

    // If we are in the middle of any all splits, they will definitely split
    // now.
    var splitParams = new Set();
    for (var multisplit in _multisplits) {
      multisplit.isSplit = true;
      splitParams.add(multisplit.param);
    }

    // TODO(rnystrom): Can optimize this to avoid the copying if there are no
    // rules in effect.
    // Take any existing split points for the current multisplits and hard split
    // them into separate lines now that we know that those splits must apply.
    var line = new Line(indent: _currentLine.indent);
    for (var chunk in _currentLine.chunks) {
      if (chunk is SplitChunk && splitParams.contains(chunk.param)) {
        var split = chunk as SplitChunk;
        buffer.writeln(new LineSplitter(_pageWidth, line).apply());
        line = new Line(indent: split.indent);
      } else {
        line.chunks.add(chunk);
      }
    }

    buffer.writeln(new LineSplitter(_pageWidth, line).apply());

    _currentLine = null;
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// In most cases, this just appends it to the current line. However, if
  /// [string] is for a multi-line string, it will span multiple lines. In that
  /// case, this splits it into lines and handles each line separately.
  void write(String string) {
    _ensureLine();

    var lines = string.split(lineSeparator);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      _currentLine.write(line);
      if (i != lines.length - 1) {
        newline();

        // Do not indent multi-line strings since we are inside the middle of
        // the string literal itself.
        clearIndentation();
      }
    }
  }

  void split(SplitChunk split) {
    // If this split is associated with a multisplit that's already been split,
    // treat it like a hard newline.
    var isSplit = false;
    for (var multisplit in _multisplits) {
      if (multisplit.isSplit && multisplit.param == split.param) {
        isSplit = true;
        break;
      }
    }

    if (isSplit) {
      // The line up to the split is complete now.
      if (_currentLine != null) {
        buffer.writeln(new LineSplitter(_pageWidth, _currentLine).apply());
      }

      // Use the split's indent for the next line.
      _currentLine = new Line(indent: split.indent);
      return;
    }

    _ensureLine();
    _currentLine.chunks.add(split);
  }

  /// Add a mark at the current position in the current line for the [rule].
  void ruleMark(SplitRule rule) {
    _ensureLine();
    _currentLine.chunks.add(new RuleChunk(rule));
  }

  void startMultisplit([int cost = SplitCost.FREE]) {
    _multisplits.add(new Multisplit(cost));
  }

  void multisplit({int indent: 0, String text: ""}) {
    split(new SplitChunk(this.indent + indent, param: _multisplits.last.param,
        text: text));
  }

  void endMultisplit() {
    _multisplits.removeLast();
  }

  String toString() {
    var source = new StringBuffer(buffer.toString());

    if (_currentLine != null) {
      source.write(new LineSplitter(_pageWidth, _currentLine).apply());
    }

    return source.toString();
  }

  /// Lazily initializes [_currentLine] if not already created.
  void _ensureLine() {
    if (_currentLine != null) return;
    _currentLine = new Line(indent: indent);
  }
}
