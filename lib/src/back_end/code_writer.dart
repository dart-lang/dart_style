// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:math';

import '../piece/piece.dart';
import 'solution.dart';
import 'solution_cache.dart';

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

  /// Previously cached formatted subtrees.
  final SolutionCache _cache;

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

  /// The stack indentation levels.
  ///
  /// Each entry in the stack is the absolute number of spaces of leading
  /// indentation that should be written when beginning a new line to account
  /// for block nesting, expression wrapping, constructor initializers, etc.
  final List<_Indent> _indentStack = [];

  /// The stack of regions created by pairs of calls to [pushAllowNewlines()]
  /// and [popAllowNewlines()].
  final List<bool> _allowNewlineStack = [true];

  /// Whether any newlines have been written during the [_currentPiece] being
  /// formatted.
  bool _hadNewline = false;

  /// The current innermost piece being formatted by a call to [format()].
  Piece? _currentPiece;

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

  /// [leadingIndent] is the number of spaces of leading indentation at the
  /// beginning of each line independent of indentation created by pieces being
  /// written.
  CodeWriter(this._pageWidth, int leadingIndent, this._cache, this._solution) {
    _indentStack.add(_Indent(leadingIndent, 0));

    // Write the leading indent before the first line.
    _buffer.write(' ' * leadingIndent);
    _column = leadingIndent;
  }

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

  /// Increases the number of spaces of indentation by [indent] relative to the
  /// current amount of indentation.
  ///
  /// If [canCollapse] is `true`, then the new [indent] spaces of indentation
  /// are "collapsible". This means that further calls to [pushIndent()] will
  /// merge their indentation with [indent] and not increase the visible
  /// indentation until more than [indent] spaces of indentation have been
  /// increased.
  void pushIndent(int indent, {bool canCollapse = false}) {
    var parentIndent = _indentStack.last.indent;
    var parentCollapse = _indentStack.last.collapsible;

    if (parentCollapse == indent) {
      // We're indenting by the same existing collapsible amount, so collapse
      // this new indentation with that existing one.
      _indentStack.add(_Indent(parentIndent, 0));
    } else if (canCollapse) {
      // We should never get multiple levels of nested collapsible indentation.
      assert(parentCollapse == 0);

      // Increase the indentation and note that it can be collapsed with
      // further indentation.
      _indentStack.add(_Indent(parentIndent + indent, indent));
    } else {
      // Regular indentation, so just increase the indent.
      _indentStack.add(_Indent(parentIndent + indent, 0));
    }
  }

  /// Discards the indentation change from the last call to [pushIndent()].
  void popIndent() {
    _indentStack.removeLast();
  }

  /// Begins a region of formatting where newlines are allowed if [allow] is
  /// `true` or prohibited otherwise.
  ///
  /// If a newline is written while the top of the stack is `false`, the entire
  /// solution is considered invalid and gets discarded.
  ///
  /// The region is ended by a corresponding call to [popAllowNewlines()].
  void pushAllowNewlines(bool allow) {
    _allowNewlineStack.add(allow);
  }

  /// Ends the region begun by the most recent call to [pushAllowNewlines()].
  void popAllowNewlines() {
    _allowNewlineStack.removeLast();
  }

  /// Inserts a newline if [condition] is true.
  ///
  /// If [space] is `true` and [condition] is `false`, writes a space.
  ///
  /// If [blank] is `true`, writes an extra newline to produce a blank line.
  void splitIf(bool condition, {bool space = true, bool blank = false}) {
    if (condition) {
      newline(blank: blank);
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
  /// If [flushLeft] is `true`, then the new line begins at column 1 and ignores
  /// any surrounding indentation. This is used for multi-line block comments
  /// and multi-line strings.
  void newline({bool blank = false, bool flushLeft = false}) {
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
      _pendingIndent = flushLeft ? 0 : _indentStack.last.indent;
    }

    _pendingWhitespace = _pendingWhitespace.collapse(whitespace);
  }

  /// Format [piece] and insert the result into the code being written and
  /// returned by [finish()].
  ///
  /// If [separate] is `true`, then [piece] is formatted and solved using a
  /// separate Solver and the result inserted into this CodeWriter's Solution.
  /// This lets us solve branches of the piece tree separately and compose the
  /// optimal results together.
  ///
  /// It's only safe to pass [separate] when the piece's formatting depends
  /// only on its starting indentation and state. If the piece's formatting can
  /// be affected by the contents of the current line, the contents after the
  /// piece's ending line, or constraints between pieces, then [separate] should
  /// be `false`. It's up to the parent piece to only call this when it's safe
  /// to do so. In practice, this usually means when the parent piece knows that
  /// [piece] will have a newline before and after it.
  void format(Piece piece, {bool separate = false}) {
    if (separate) {
      _formatSeparate(piece);
    } else {
      _formatInline(piece);
    }
  }

  /// Format [piece] using a separate [Solver] and merge the result into this
  /// writer's [_solution].
  void _formatSeparate(Piece piece) {
    var solution = _cache.find(
        _pageWidth, piece, _pendingIndent, _solution.pieceStateIfBound(piece));

    _pendingIndent = 0;
    _flushWhitespace();

    _solution.mergeSubtree(solution);

    // If a selection marker was in the child piece, set it in this piece,
    // relative to where the child's code is appended.
    if (solution.selectionStart case var start?) {
      _solution.startSelection(_buffer.length + start);
    }

    if (solution.selectionEnd case var end?) {
      _solution.endSelection(_buffer.length + end);
    }

    _buffer.write(solution.text);
  }

  /// Format [piece] writing directly into this [CodeWriter].
  void _formatInline(Piece piece) {
    // Begin a new formatting context for this child.
    var previousPiece = _currentPiece;
    _currentPiece = piece;

    var previousHadNewline = _hadNewline;
    _hadNewline = false;

    var isUnsolved =
        !_solution.isBound(piece) && piece.additionalStates.isNotEmpty;
    if (isUnsolved) _currentUnsolvedPieces.add(piece);

    // Format the child piece.
    piece.format(this, _solution.pieceState(piece));

    // Restore the surrounding piece's context.
    if (isUnsolved) _currentUnsolvedPieces.removeLast();

    var childHadNewline = _hadNewline;
    _hadNewline = previousHadNewline;

    _currentPiece = previousPiece;

    // If the child contained a newline then the parent transitively does.
    if (childHadNewline && _currentPiece != null) _handleNewline();
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
    if (!_allowNewlineStack.last) _solution.invalidate(_currentPiece!);

    // Note that this piece contains a newline so that we can propagate that
    // up to containing pieces too.
    _hadNewline = true;
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

  /// Whether this whitespace contains at least one newline.
  bool get hasNewline => switch (this) {
        newline || blankLine => true,
        _ => false,
      };
}

/// A level of indentation in the indentation stack.
class _Indent {
  /// The total number of spaces of indentation.
  final int indent;

  /// How many spaces of [indent] can be collapsed with further indentation.
  final int collapsible;

  _Indent(this.indent, this.collapsible);
}
