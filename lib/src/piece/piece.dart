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
  /// The ordered list of indexes identifying each way this piece can split.
  ///
  /// Each piece determines what each value in the list represents. The list
  /// returned by this function should be sorted so that earlier states in the
  /// list compare less than later states.
  ///
  /// In addition to the values returned here, each piece should implicitly
  /// support a [State.initial] which is the least split form the piece allows.
  List<State> get states;

  /// Given that this piece is in [state], use [writer] to produce its formatted
  /// output.
  void format(CodeWriter writer, State state);

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
  List<State> get states => const [];

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
  void format(CodeWriter writer, State state) {
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

/// A state that a piece can be in.
///
/// Each state identifies one way that a piece can be split into multiple lines.
/// Each piece determines how its states are interpreted.
class State implements Comparable<State> {
  static const initial = State(0);

  /// The maximally split state a piece can be in.
  ///
  /// The value here is somewhat arbitrary. It just needs to be larger than
  /// any other value used by any [Piece] that uses this [State].
  static const split = State(255);

  final int _value;

  const State(this._value);

  @override
  int compareTo(State other) => _value.compareTo(other._value);

  @override
  String toString() => '◦$_value';
}
