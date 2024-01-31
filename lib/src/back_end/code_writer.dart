// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:math';

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
class CodeWriter {
  final int _pageWidth;

  /// The solution this [CodeWriter] is generating code for.
  final Solution _solution;

  /// Buffer for the code being written.
  final StringBuffer _buffer = StringBuffer();

  /// What whitespace should be written before the next non-whitespace text.
  ///
  /// When whitespace is written, instead of immediately writing it, we queue
  /// it as pending. This ensures that we don't write trailing whitespace,
  /// avoids writing spaces at the beginning of lines, and allows collapsing
  /// multiple redundant newlines.
  Whitespace _pendingWhitespace = Whitespace.none;

  /// The number of spaces of indentation that should be begin the next line
  /// when [_pendingWhitespace] is [Whitespace.newline] or
  /// [Whitespace.blankLine].
  int _pendingIndent = 0;

  /// The number of characters in the line currently being written.
  int _column = 0;

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
  final List<_PieceOptions> _options = [];

  /// Whether we have already found the first line where whose piece should be
  /// used to expand further solutions.
  ///
  /// This is the first line that either overflows or contains an invalid
  /// newline. When expanding solutions, we use the first solvable piece on
  /// this line.
  bool _foundExpandLine = false;

  /// The first solvable piece on the first overflowing or invalid line, if
  /// we've found one.
  ///
  /// A piece is "solvable" if we haven't already bound it to a state and there
  /// are multiple states it accepts. This is the piece whose states will be
  /// bound when we expand the [Solution] that this [CodeWriter] is building
  /// into further solutions.
  ///
  /// If [_foundExpandLine] is `false`, then this is the first solvable piece
  /// that has written text to the current line. It may not actually be an
  /// expand piece. We don't know until we reach the end of the line to see if
  /// it overflows or is invalid. If the line is OK, then [_nextPieceToExpand]
  /// is cleared when the next line begins. If [_foundExpandLine] is `true`,
  /// then this known to be the piece that will be expanded next for this
  /// solution.
  Piece? _nextPieceToExpand;

  /// The stack of solvable pieces currently being formatted.
  ///
  /// We use this to track which pieces are in play when text is written to the
  /// current line so that we know which piece should be expanded in the next
  /// solution if the line ends up overflowing.
  final List<Piece> _currentUnsolvedPieces = [];

  CodeWriter(this._pageWidth, this._solution);

  /// Returns the final formatted text and the next piece that can be expanded
  /// from the solution this [CodeWriter] is writing, if any.
  (String, Piece?) finish() {
    _finishLine();

    return (_buffer.toString(), _nextPieceToExpand);
  }

  /// Appends [text] to the output.
  ///
  /// If [text] contains any internal newlines, the caller is responsible for
  /// also calling [handleNewline()].
  void write(String text) {
    // TODO(tall): Calling this directly from pieces outside of TextPiece may
    // not handle selections as gracefully as we could. A selection marker may
    // get pushed past the text written here. Currently, this is only called
    // directly for commas in list-like things, and `;` in for loops. In
    // general, it's better for all text written to the output to live inside
    // TextPieces because that will preserve selection markers. Consider doing
    // something smarter for commas in lists and semicolons in for loops.

    _flushWhitespace();
    _buffer.write(text);
    _column += text.length;

    // If we haven't found an overflowing line yet, then this line might be one
    // so keep track of the pieces we've encountered.
    if (!_foundExpandLine &&
        _nextPieceToExpand == null &&
        _currentUnsolvedPieces.isNotEmpty) {
      _nextPieceToExpand = _currentUnsolvedPieces.first;
    }
  }

  /// Sets the number of spaces of indentation for code written by the current
  /// piece to [indent], relative to the indentation of the surrounding piece.
  ///
  /// Replaces any previous indentation set by this piece.
  // TODO(tall): Add another API that adds/subtracts existing indentation.
  void setIndent(int indent) {
    var parentIndent = 0;

    // If there is a surrounding Piece, then set the indent relative to that
    // piece's current indentation.
    if (_options.length > 1) {
      parentIndent = _options[_options.length - 2].indent;
    }

    _options.last.indent = parentIndent + indent;
  }

  /// Inserts a newline if [condition] is true.
  ///
  /// If [space] is `true` and [condition] is `false`, writes a space.
  ///
  /// If [blank] is `true`, writes an extra newline to produce a blank line.
  ///
  /// If [indent] is given, sets the amount of block-level indentation for this
  /// and all subsequent newlines to [indent].
  void splitIf(bool condition,
      {bool space = true, bool blank = false, int? indent}) {
    if (condition) {
      newline(blank: blank, indent: indent);
    } else if (space) {
      this.space();
    }
  }

  /// Writes a single space to the output.
  void space() {
    whitespace(Whitespace.space);
  }

  /// Inserts a line split in the output.
  ///
  /// If [blank] is `true`, writes an extra newline to produce a blank line.
  ///
  /// If [indent] is given, set the indentation of the new line (and all
  /// subsequent lines) to that indentation relative to the containing piece.
  ///
  /// If [flushLeft] is `true`, then the new line begins at column 1 and ignores
  /// any surrounding indentation. This is used for multi-line block comments
  /// and multi-line strings.
  void newline({bool blank = false, int? indent, bool flushLeft = false}) {
    if (indent != null) setIndent(indent);

    whitespace(blank ? Whitespace.blankLine : Whitespace.newline,
        flushLeft: flushLeft);
  }

  /// Queues [whitespace] to be written to the output.
  ///
  /// If any non-whitespace is written after this call, then this whitespace
  /// will be written first. Also handles merging multiple kinds of whitespace
  /// intelligently together.
  ///
  /// If [flushLeft] is `true`, then the new line begins at column 1 and ignores
  /// any surrounding indentation. This is used for multi-line block comments
  /// and multi-line strings.
  void whitespace(Whitespace whitespace, {bool flushLeft = false}) {
    if (whitespace case Whitespace.newline || Whitespace.blankLine) {
      _handleNewline();
      _pendingIndent = flushLeft ? 0 : _options.last.indent;
    }

    _pendingWhitespace = _pendingWhitespace.collapse(whitespace);
  }

  /// Sets whether newlines are allowed to occur from this point on for the
  /// current piece.
  void setAllowNewlines(bool allowed) {
    _options.last.allowNewlines = allowed;
  }

  /// Format [piece] and insert the result into the code being written and
  /// returned by [finish()].
  void format(Piece piece) {
    _options.add(_PieceOptions(piece, _options.lastOrNull?.indent ?? 0,
        _options.lastOrNull?.allowNewlines ?? true));

    var isUnsolved = !_solution.isBound(piece) && piece.states.length > 1;
    if (isUnsolved) _currentUnsolvedPieces.add(piece);

    // TODO(perf): Memoize this. Might want to create a nested PieceWriter
    // instead of passing in `this` so we can better control what state needs
    // to be used as the key in the memoization table.
    piece.format(this, _solution.pieceState(piece));

    if (isUnsolved) _currentUnsolvedPieces.removeLast();

    var childOptions = _options.removeLast();

    // If the child [piece] contains a newline then this one transitively does.
    if (childOptions.hasNewline && _options.isNotEmpty) _handleNewline();
  }

  /// Format [piece] if not null.
  void formatOptional(Piece? piece) {
    if (piece != null) format(piece);
  }

  /// Sets [selectionStart] to be [start] code units into the output.
  void startSelection(int start) {
    _flushWhitespace();
    _solution.startSelection(_buffer.length + start);
  }

  /// Sets [selectionEnd] to be [end] code units into the output.
  void endSelection(int end) {
    _flushWhitespace();
    _solution.endSelection(_buffer.length + end);
  }

  /// Notes that a newline has been written.
  ///
  /// If this occurs in a place where newlines are prohibited, then invalidates
  /// the solution.
  void _handleNewline() {
    if (!_options.last.allowNewlines) _solution.invalidate(_options.last.piece);

    // Note that this piece contains a newline so that we can propagate that
    // up to containing pieces too.
    _options.last.hasNewline = true;
  }

  /// Write any pending whitespace.
  ///
  /// This is called before non-whitespace text is about to be written, or
  /// before the selection is updated since the latter requires an accurate
  /// count of the written text, including whitespace.
  void _flushWhitespace() {
    switch (_pendingWhitespace) {
      case Whitespace.none:
        break; // Nothing to do.

      case Whitespace.newline:
      case Whitespace.blankLine:
        _finishLine();
        _buffer.writeln();
        if (_pendingWhitespace == Whitespace.blankLine) _buffer.writeln();

        _column = _pendingIndent;
        _buffer.write(' ' * _column);

      case Whitespace.space:
        _buffer.write(' ');
        _column++;
    }

    _pendingWhitespace = Whitespace.none;
  }

  void _finishLine() {
    // If the completed line is too long, track the overflow.
    if (_column >= _pageWidth) {
      _solution.addOverflow(_column - _pageWidth);
    }

    // If we found a problematic line, and there is a piece on the line that
    // we can try to split, then remember that piece so that the solution will
    // expand it next.
    if (!_foundExpandLine &&
        _nextPieceToExpand != null &&
        (_column > _pageWidth || !_solution.isValid)) {
      // We found a problematic line, so remember it and the piece on it.
      _foundExpandLine = true;
    } else if (!_foundExpandLine) {
      // This line was OK, so we don't need to expand the piece on it.
      _nextPieceToExpand = null;
    }
  }
}

/// Different kinds of pending whitespace that have been requested.
///
/// Note that the order of values in the enum is significant: later ones have
/// more whitespace than previous ones.
enum Whitespace {
  /// No pending whitespace.
  none,

  /// A single space.
  space,

  /// A single newline.
  newline,

  /// Two newlines.
  blankLine;

  /// Combines two pending whitespaces and returns the result.
  ///
  /// When two whitespaces overlap, they aren't both written: we don't want
  /// two spaces or a newline followed by a space. Instead, the two whitespaces
  /// are collapsed such that the largest one wins.
  Whitespace collapse(Whitespace other) => values[max(index, other.index)];
}

/// The mutable state local to a single piece being formatted.
class _PieceOptions {
  /// The piece being formatted with these options.
  final Piece piece;

  /// The absolute number of spaces of leading indentation coming from
  /// block-like structure or explicit extra indentation (aligning constructor
  /// initializers, `show` clauses, etc.).
  int indent;

  /// Whether newlines are allowed to occur.
  ///
  /// If a newline is written while this is `false`, the entire solution is
  /// considered invalid and gets discarded.
  bool allowNewlines;

  /// Whether any newlines have occurred in this piece or any of its children.
  bool hasNewline = false;

  _PieceOptions(this.piece, this.indent, this.allowNewlines);
}
