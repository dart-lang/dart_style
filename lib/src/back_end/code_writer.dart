// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../constants.dart';
import '../piece/piece.dart';
import 'solution.dart';

/// The interface used by [Piece]s to output formatted code.
///
/// The back-end lowers the tree of pieces to the final formatted code by
/// allowing each piece to produce the output for the code it represents.
/// This way, each piece has full flexibility for how to apply its own
/// formatting logic.
///
/// To build the resulting output code, when a piece is formatted, it is passed
/// an instance of this class. It has methods that the piece can call to add
/// output text to the resulting code, recursively format child pieces, insert
/// whitespace, etc.
///
/// This class also accumulates the score (the relative desireability of a set
/// of formatting choices) that the resulting code has by tracking things like
/// how many characters of code overflow the page width.
class CodeWriter {
  final int _pageWidth;

  /// The state values for the pieces being written.
  final PieceStateSet _pieceStates;

  /// Buffer for the code being written.
  final StringBuffer _buffer = StringBuffer();

  /// The cost of the currently chosen line splits.
  int _cost = 0;

  /// The total number of characters of code that have overflowed the page
  /// width so far.
  int _overflow = 0;

  /// The number of characters in the line currently being written.
  int _column = 0;

  /// Whether this solution has encountered a newline where none is allowed.
  ///
  /// If true, it means the solution is invalid.
  bool _containsInvalidNewline = false;

  /// The stack of state for each [Piece] being formatted.
  ///
  /// For each piece being formatted from a call to [format()], we keep track of
  /// things like indentation and nesting levels. Pieces recursively format
  /// their children. When they do, we push new values onto this stack. When a
  /// piece is done (a call to [format()] returns), we pop the corresponding
  /// state off the stack.
  ///
  /// This is used to increase the cumulative nesting as we recurse into pieces
  /// and then unwind that as child pieces are completed.
  final List<_PieceOptions> _pieceOptions = [_PieceOptions(0, 0, true)];

  /// The options for the current innermost piece being formatted.
  _PieceOptions get _options => _pieceOptions.last;

  CodeWriter(this._pageWidth, this._pieceStates);

  /// Returns the finished code produced by formatting the tree of pieces and
  /// the final score.
  (String, Score) finish() {
    _finishLine();
    return (
      _buffer.toString(),
      Score(isValid: !_containsInvalidNewline, overflow: _overflow, cost: _cost)
    );
  }

  /// Notes that a newline has been written.
  ///
  /// If this occurs in a place where newlines are prohibited, then invalidates
  /// the solution.
  ///
  /// This is called externally by [TextPiece] to let the writer know some of
  /// the raw text contains a newline, which can happen in multi-line block
  /// comments and multi-line string literals.
  void handleNewline() {
    if (!_options.allowNewlines) _containsInvalidNewline = true;
  }

  /// Appends [text] to the output.
  ///
  /// If [text] contains any internal newlines, the caller is responsible for
  /// also calling [handleNewline()].
  void write(String text) {
    _buffer.write(text);
    _column += text.length;
  }

  /// Sets the number of spaces of indentation for code written by the current
  /// piece to [indent], relative to the indentation of the surrounding piece.
  ///
  /// Replaces any previous indentation set by this piece.
  void setIndent(int indent) {
    _options.indent = _pieceOptions[_pieceOptions.length - 2].indent + indent;
  }

  /// Increase the expression nesting of the current piece if [condition] is
  /// `true`.
  void nestIf(bool condition) {
    if (!condition) return;

    _options.nesting += Indent.expression;
  }

  /// Sets the number of spaces of expression nesting for code written by the
  /// current piece to [nesting], relative to the nesting of the surrounding
  /// piece.
  ///
  /// Replaces any previous nesting set by this piece.
  void setNesting(int nesting) {
    _options.nesting =
        _pieceOptions[_pieceOptions.length - 2].nesting + nesting;
  }

  /// Inserts a newline if [condition] is true.
  ///
  /// If [space] is `true` and [condition] is `false`, writes a space.
  ///
  /// If [indent] is given, sets the amount of block-level indentation for this
  /// and all subsequent newlines to [indent].
  void splitIf(bool condition, {bool space = true, int? indent}) {
    if (indent != null) setIndent(indent);

    if (condition) {
      newline();
    } else if (space) {
      this.space();
    }
  }

  /// Writes a single space to the output.
  void space() {
    write(' ');
  }

  /// Inserts a line split in the output.
  ///
  /// If [blank] is true, writes an extra newline to produce a blank line.
  void newline({bool blank = false}) {
    handleNewline();
    _finishLine();
    _buffer.writeln();
    if (blank) _buffer.writeln();

    _column = _options.combinedIndentation;
    _buffer.write(' ' * _column);
  }

  /// Sets whether newlines are allowed to occur from this point on for the
  /// current piece or any of its children.
  void setAllowNewlines(bool allowed) {
    _options.allowNewlines = allowed;
  }

  /// Format [piece] and insert the result into the code being written and
  /// returned by [finish()].
  void format(Piece piece) {
    // Don't bother recursing into the piece tree if we know the solution will
    // be discarded.
    if (_containsInvalidNewline) return;

    // TODO(tall): Sometimes, we'll want to reset the expression nesting for
    // an inner piece, for when a block-like construct appears inside an
    // expression. If it turns out that we don't actually need to handle indent
    // and nesting separately here, then merge them into a single field.
    _pieceOptions.add(_PieceOptions(
        _options.indent, _options.nesting, _options.allowNewlines));

    var state = _pieceStates.pieceState(piece);

    // TODO(tall): Support pieces with different split costs, and possibly
    // different costs for each state value.
    if (state != 0) _cost++;

    // TODO(perf): Memoize this. Might want to create a nested PieceWriter
    // instead of passing in `this` so we can better control what state needs
    // to be used as the key in the memoization table.
    piece.format(this, state);

    _pieceOptions.removeLast();
  }

  /// Format [piece] if not null.
  void formatOptional(Piece? piece) {
    if (piece != null) format(piece);
  }

  void _finishLine() {
    // If the completed line is too long, track the overflow.
    if (_column >= _pageWidth) {
      _overflow += _column - _pageWidth;
    }
  }
}

/// The mutable state local to a single piece being formatted.
class _PieceOptions {
  /// The absolute number of spaces of leading indentation coming from
  /// block-like structure or explicit extra indentation (aligning constructor
  /// initializers, `show` clauses, etc.).
  int indent;

  /// The absolute number of spaces of indentation from wrapped expressions.
  int nesting;

  /// The total number of spaces of indentation.
  int get combinedIndentation => indent + nesting;

  /// Whether newlines are allowed to occur.
  ///
  /// If a newline is written while this is `false`, the entire solution is
  /// considered invalid and gets discarded.
  bool allowNewlines;

  _PieceOptions(this.indent, this.nesting, this.allowNewlines);
}
