// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';

/// Base class for the formatter's internal representation used for line
/// splitting.
///
/// We visit the source AST and convert it to a tree of [Piece]s. This tree
/// roughly follows the AST but includes comments and is optimized for
/// formatting and line splitting. The final output is then determined by
/// deciding which pieces split and how.
abstract class Piece {
  /// The number of different ways this piece can be split.
  ///
  /// States are numbered incrementally starting at zero. State zero should
  /// always be the lowest cost state with the fewest line splits. Lower states
  /// should generally be preferred over higher states.
  int get stateCount;

  /// Given that this piece is in [state], use [writer] to produce its formatted
  /// output.
  void format(CodeWriter writer, int state);

  /// Invokes [callback] on each piece contained in this piece.
  void forEachChild(void Function(Piece piece) callback);
}

/// A simple atomic piece of code.
///
/// This may represent a series of tokens where no split can occur between them.
/// It may also contain one or more comments.
class TextPiece extends Piece {
  /// The lines of text in this piece.
  ///
  /// Most [TextPieces] will contain only a single line, but a piece with
  /// preceding comments that are on their own line will have multiple. These
  /// are stored as separate lines instead of a single multi-line string so that
  /// each line can be indented appropriately during formatting.
  final List<String> _lines = [];

  /// True if this text piece contains or ends with a mandatory newline.
  ///
  /// This can be from line comments, block comments with newlines inside,
  /// multiline strings, etc.
  bool _containsNewline = false;

  @override
  int get stateCount => 1;

  /// Whether the last line of this piece's text ends with [text].
  bool endsWith(String text) => _lines.isNotEmpty && _lines.last.endsWith(text);

  /// Append [text] to the end of this piece.
  ///
  /// If [text] internally contains a newline, then [containsNewline] should
  /// be `true`.
  void append(String text, {bool containsNewline = false}) {
    if (_lines.isEmpty) _lines.add('');

    // TODO(perf): Consider a faster way of accumulating text.
    _lines.last = _lines.last + text;

    if (containsNewline) _containsNewline = true;
  }

  void newline() {
    _lines.add('');
  }

  @override
  void format(CodeWriter writer, int state) {
    // Let the writer know if there are any embedded newlines even if there is
    // only one "line" in [_lines].
    if (_containsNewline) writer.handleNewline();

    for (var i = 0; i < _lines.length; i++) {
      if (i > 0) writer.newline();
      writer.write(_lines[i]);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {}

  @override
  String toString() => '`${_lines.join('¬')}`${_containsNewline ? '!' : ''}';
}
