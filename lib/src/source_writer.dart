// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'line.dart';
import 'line_splitter.dart';

class SourceWriter {
  final buffer = new StringBuffer();

  final String lineSeparator;

  /// The current indentation level.
  ///
  /// Subsequent lines will be created with this much leading indentation.
  int indent = 0;

  bool get isCurrentLineEmpty => _currentLine == null;

  final int _pageWidth;

  /// `true` if the next line should have its indentation cleared instead of
  /// using [indent].
  bool _clearNextIndent = false;

  /// The line currently being written to, or `null` if a non-empty line has
  /// not been started yet.
  Line _currentLine;

  /// The nested stack of multisplits that are currently being written.
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

  /// The nested stack of spans that are currently being written.
  final _spans = <SpanStartChunk>[];

  SourceWriter({this.indent: 0, this.lineSeparator: "\n", int pageWidth: 80})
      : _pageWidth = pageWidth;

  /// Forces the next line written to have no leading indentation.
  void clearIndentation() {
    _clearNextIndent = true;
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
    _splitMultisplits();

    buffer.writeln(new LineSplitter(_pageWidth, _currentLine).apply());

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
      _ensureLine();
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

  void startSpan() {
    _ensureLine();
    _spans.add(new SpanStartChunk());
    _currentLine.chunks.add(_spans.last);
  }

  void endSpan(int cost) {
    _ensureLine();
    _currentLine.chunks.add(new SpanEndChunk(_spans.removeLast(), cost));
  }

  void startMultisplit([int cost = SplitCost.FREE]) {
    _multisplits.add(new Multisplit(cost));
  }

  void multisplit({int indent: 0, String text: ""}) {
    split(new SplitChunk(this.indent + indent, _multisplits.last.param, text));
  }

  void endMultisplit() {
    // Check to see if the body of the multisplit is longer than a line. If so,
    // we know it will definitely split and we can do this pre-emptively here
    // instead of having the line splitter try it. This is much faster than
    // having the line splitter try combinations of this param along with
    // others.
    if (!_multisplits.last.isSplit) {
      var started = false;
      var length = 0;
      for (var chunk in _currentLine.chunks) {
        if (!started && chunk is SplitChunk &&
            chunk.param == _multisplits.last.param) {
          started = true;
        } else if (started) {
          length += chunk.text.length;
        }
      }

      if (length > _pageWidth) _splitMultisplits();
    }

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
    _currentLine = new Line(indent: _clearNextIndent ? 0 : indent);
    _clearNextIndent = false;
  }

  /// Forces all multisplits in the current line to be split and breaks the
  /// line into multiple independent [Line] objects, each of which is printed
  /// separately (except for the last one, which is still in-progress).
  void _splitMultisplits() {
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

    _currentLine = line;
  }
}
