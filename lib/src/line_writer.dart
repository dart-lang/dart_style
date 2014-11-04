// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'dart_formatter.dart';
import 'line.dart';
import 'line_splitter.dart';

/// The kind of pending whitespace that has been "written", but not actually
/// physically output yet.
///
/// We defer actually writing whitespace until a non-whitespace token is
/// encountered to avoid trailing whitespace.
class Whitespace {
  /// A single non-breaking space.
  static const SPACE = const Whitespace._("SPACE");

  /// A single newline.
  static const NEWLINE = const Whitespace._("NEWLINE");

  /// Two newlines, a single blank line of separation.
  static const TWO_NEWLINES = const Whitespace._("TWO_NEWLINES");

  /// A space or newline should be output based on whether the current token is
  /// on the same line as the previous one or not.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const SPACE_OR_NEWLINE = const Whitespace._("SPACE_OR_NEWLINE");

  /// One or two newlines should be output based on how many newlines are
  /// present between the next token and the previous one.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const ONE_OR_TWO_NEWLINES = const Whitespace._("ONE_OR_TWO_NEWLINES");

  final String name;

  const Whitespace._(this.name);

  String toString() => name;
}

/// The "middle" of the formatting pipeline for taking in text, newlines, and
/// chunks and emitting a series of logical (but unsplit) [Line]s.
///
/// This is written to by [SourceVisitor]. As each [Line] is completed, it gets
/// fed to a [LineSplitter], which ensures the resulting line stays with the
/// page boundary.
class LineWriter {
  final StringBuffer buffer;

  /// The current indentation level.
  ///
  /// Subsequent lines will be created with this much leading indentation.
  int indent = 0;

  final DartFormatter _formatter;

  /// The whitespace that should be written before the next non-whitespace token
  /// or `null` if no whitespace is pending.
  Whitespace _pendingWhitespace;

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

  LineWriter(this._formatter, this.buffer) {
    indent = _formatter.indent;
  }

  /// Forces the next line written to have no leading indentation.
  void clearIndentation() {
    _clearNextIndent = true;
  }

  /// Prints the current line and completes it.
  ///
  /// If no tokens have been written since the last line was ended, this still
  /// prints an empty line.
  void _newline() {
    if (_currentLine == null) {
      buffer.write(_formatter.lineEnding);
      return;
    }

    // If we are in the middle of any all splits, they will definitely split
    // now.
    _splitMultisplits();

    _finishLine(_currentLine);
    buffer.write(_formatter.lineEnding);

    _currentLine = null;
  }

  /// Writes [string], the text for a single token, to the output.
  void write(String string) {
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.SPACE:
        if (_currentLine != null) _currentLine.write(" ");
        break;

      case Whitespace.NEWLINE:
        _newline();
        break;

      case Whitespace.TWO_NEWLINES:
        _newline();
        _newline();
        break;

      case Whitespace.SPACE_OR_NEWLINE:
      case Whitespace.ONE_OR_TWO_NEWLINES:
        // We should have pinned these down before getting here.
        assert(false);
    }

    _pendingWhitespace = null;

    _ensureLine();
    _currentLine.write(string);
  }

  /// Sets [whitespace] to be emitted before the next non-whitespace token.
  void writeWhitespace(Whitespace whitespace) {
    _pendingWhitespace = whitespace;
  }

  /// Updates the pending whitespace to a more precise amount given that the
  /// next token is [numLines] farther down from the previous token.
  void suggestWhitespace(int numLines) {
    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pendingWhitespace) {
      case Whitespace.SPACE_OR_NEWLINE:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.NEWLINE;
        } else {
          _pendingWhitespace = Whitespace.SPACE;
        }
        break;

      case Whitespace.ONE_OR_TWO_NEWLINES:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.TWO_NEWLINES;
        } else {
          _pendingWhitespace = Whitespace.NEWLINE;
        }
        break;
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
        _finishLine(_currentLine);
        buffer.write(_formatter.lineEnding);
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
    // instead of having the line splitter try it. This is faster than
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

      if (length > _formatter.pageWidth) _splitMultisplits();
    }

    _multisplits.removeLast();
  }

  /// Makes sure we have written one last trailing newline at the end of a
  /// compilation unit.
  void ensureNewline() {
    // If we already completed a line and haven't started a new one, there is
    // a trailing newline.
    if (_currentLine == null) return;

    _newline();
  }

  /// Finish writing the last line.
  void end() {
    if (_currentLine != null) _finishLine(_currentLine);
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
        _finishLine(line);
        buffer.write(_formatter.lineEnding);
        line = new Line(indent: split.indent);
      } else {
        line.chunks.add(chunk);
      }
    }

    _currentLine = line;
  }

  void _finishLine(Line line) {
    var splitter = new LineSplitter(_formatter.lineEnding,
        _formatter.pageWidth, line);
    splitter.apply(buffer);
  }
}
