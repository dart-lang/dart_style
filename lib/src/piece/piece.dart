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
  /// The ordered list of ways this piece may split.
  ///
  /// If the piece is aready pinned, then this is just the one pinned state.
  /// Otherwise, it's [State.unsplit], which all pieces support, followed by
  /// any other [additionalStates].
  List<State> get states {
    if (_pinnedState case var state?) {
      return [state];
    } else {
      return [State.unsplit, ...additionalStates];
    }
  }

  /// The ordered list of all possible ways this piece could split.
  ///
  /// Piece subclasses should override this if they support being split in
  /// multiple different ways.
  ///
  /// Each piece determines what each [State] in the list represents, including
  /// the automatically included [State.unsplit]. The list returned by this
  /// function should be sorted so that earlier states in the list compare less
  /// than later states.
  List<State> get additionalStates => const [];

  /// If this piece has been pinned to a specific state, that state.
  ///
  /// This is used when a piece which otherwise supports multiple ways of
  /// splitting should be eagerly constrained to a specific splitting choice
  /// because of the context where it appears. For example, if conditional
  /// expressions are nested, then all of them are forced to split because it's
  /// too hard to read nested conditionals all on one line. We can express that
  /// by pinning the Piece used for a conditional expression to its split state
  /// when surrounded by or containing other conditionals.
  State? get pinnedState => _pinnedState;
  State? _pinnedState;

  /// Given that this piece is in [state], use [writer] to produce its formatted
  /// output.
  void format(CodeWriter writer, State state);

  /// Invokes [callback] on each piece contained in this piece.
  void forEachChild(void Function(Piece piece) callback);

  /// Forces this piece to always use [state].
  void pin(State state) {
    _pinnedState = state;
  }

  /// The name of this piece as it appears in debug output.
  ///
  /// By default, this is the class's name with `Piece` removed.
  String get debugName => runtimeType.toString().replaceAll('Piece', '');

  @override
  String toString() => debugName;
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

  /// Whitespace at the end of this [TextPiece].
  ///
  /// This will be turned into actual text if non-whitespace is written after
  /// the pending whitespace is set. Otherwise, it will be written to the output
  /// when the [TextPiece] is formatted.
  ///
  /// Initially [Whitespace.newline] so that we insert a new string into the
  /// empty [_lines] list on the first write.
  Whitespace _trailingWhitespace = Whitespace.newline;

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionEnd;

  /// Whether the last line of this piece's text ends with [text].
  bool endsWith(String text) => _lines.isNotEmpty && _lines.last.endsWith(text);

  /// Append [text] to the end of this piece.
  ///
  /// If [text] internally contains a newline, then [containsNewline] should
  /// be `true`.
  void append(String text, {bool containsNewline = false}) {
    // Write any pending whitespace into the text.
    switch (_trailingWhitespace) {
      case Whitespace.none:
        break; // Nothing to do.
      case Whitespace.space:
        // TODO(perf): Consider a faster way of accumulating text.
        _lines.last += ' ';
      case Whitespace.newline:
        _lines.add('');
      case Whitespace.blankLine:
        throw UnsupportedError('No blank lines in TextPieces.');
    }

    _trailingWhitespace = Whitespace.none;

    // TODO(perf): Consider a faster way of accumulating text.
    _lines.last = _lines.last + text;

    if (containsNewline) _containsNewline = true;
  }

  void space() {
    _trailingWhitespace = _trailingWhitespace.collapse(Whitespace.space);
  }

  void newline() {
    _trailingWhitespace = _trailingWhitespace.collapse(Whitespace.newline);
  }

  @override
  void format(CodeWriter writer, State state) {
    // Let the writer know if there are any embedded newlines even if there is
    // only one "line" in [_lines].
    if (_containsNewline) writer.handleNewline();

    if (_selectionStart case var start?) {
      writer.startSelection(start);
    }

    if (_selectionEnd case var end?) {
      writer.endSelection(end);
    }

    for (var i = 0; i < _lines.length; i++) {
      if (i > 0) writer.newline();
      writer.write(_lines[i]);
    }

    writer.whitespace(_trailingWhitespace);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {}

  /// Sets [selectionStart] to be [start] code units after the end of the
  /// current text in this piece.
  void startSelection(int start) {
    _selectionStart = _adjustSelection(start);
  }

  /// Sets [selectionEnd] to be [end] code units after the end of the
  /// current text in this piece.
  void endSelection(int end) {
    _selectionEnd = _adjustSelection(end);
  }

  /// Adjust [offset] by the current length of this [TextPiece].
  int _adjustSelection(int offset) {
    for (var line in _lines) {
      offset += line.length;
    }

    if (_trailingWhitespace == Whitespace.space) offset++;

    return offset;
  }

  @override
  String toString() => '`${_lines.join('¬')}`${_containsNewline ? '!' : ''}';
}

/// A piece that writes a single space.
class SpacePiece extends Piece {
  @override
  void forEachChild(void Function(Piece piece) callback) {}

  @override
  void format(CodeWriter writer, State state) {
    writer.space();
  }
}

/// A state that a piece can be in.
///
/// Each state identifies one way that a piece can be split into multiple lines.
/// Each piece determines how its states are interpreted.
class State implements Comparable<State> {
  static const unsplit = State(0, cost: 0);

  /// The maximally split state a piece can be in.
  ///
  /// The value here is somewhat arbitrary. It just needs to be larger than
  /// any other value used by any [Piece] that uses this [State].
  static const split = State(255);

  final int _value;

  /// How much a solution is penalized when this state is chosen.
  final int cost;

  const State(this._value, {this.cost = 1});

  @override
  int compareTo(State other) => _value.compareTo(other._value);

  @override
  String toString() => '◦$_value';
}
