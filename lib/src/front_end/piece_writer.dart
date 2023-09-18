// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/solver.dart';
import '../dart_formatter.dart';
import '../debug.dart' as debug;
import '../piece/piece.dart';
import '../source_code.dart';

/// Incrementally builds [Piece]s while visiting AST nodes.
///
/// The nodes in the piece tree don't always map precisely to AST nodes. For
/// example, in:
///
/// ```
/// a + b;
/// ```
///
/// The AST structure is like:
///
/// ```
/// ExpressionStatement
///   BinaryExpression
///     SimpleIdentifier("a")
///     Token("+")
///     SimpleIdentifier("b")
/// ```
///
/// But the resulting piece tree looks like:
///
/// ```
/// Infix
///   TextPiece("a +")
///   TextPiece("b;")
/// ```
///
/// Note how the infix operator is attached to the preceding piece (which
/// happens to just be text but could be a more complex piece if the left
/// operand was a nested expression). Notice also that there is no piece for
/// the expression statement and instead, the `;` is just appended to the last
/// piece which is conceptually deeply nested inside the binary expression.
///
/// This class implements the "slippage" between these two representations. It
/// has mutable state to allow incrementally building up pieces while traversing
/// the source AST nodes.
class PieceWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  /// The current [TextPiece] being written to or `null` if no text piece has
  /// been started yet.
  TextPiece? get currentText => _currentText;
  TextPiece? _currentText;

  /// The most recently pushed piece, waiting to be taken by some surrounding
  /// piece.
  ///
  /// Since we traverse the AST in syntax order and pop built pieces on the way
  /// back up, the "stack" of completed pieces is only ever one deep at the
  /// most, so we model it with just a single field.
  Piece? _pushed;

  /// Whether we should write a space before the next text that is written.
  bool _pendingSpace = false;

  /// Whether we should write a newline in the current [TextPiece] before the
  /// next text that is written.
  bool _pendingNewline = false;

  /// Whether we should create a new [TextPiece] the next time text is written.
  bool _pendingSplit = false;

  PieceWriter(this._formatter, this._source);

  /// Gives the builder a newly completed [piece], to be taken by a later call
  /// to [pop] from some surrounding piece.
  void push(Piece piece) {
    // Should never push more than one piece.
    assert(_pushed == null);

    _pushed = piece;
  }

  /// Captures the most recently created complete [Piece].
  ///
  /// If the most recent operation was [push], then this returns the piece given
  /// by that call. Otherwise, returns the piece created by the preceding calls
  /// to [write] since the last split.
  Piece pop() {
    if (_pushed case var piece?) {
      _pushed = null;
      return piece;
    }

    return _currentText!;
  }

  /// Ends the current text piece and (lazily) begins a new one.
  ///
  /// The previous text piece should already be taken.
  void split() {
    _pendingSplit = true;
  }

  /// Writes a space to the current [TextPiece].
  void space() {
    _pendingSpace = true;
  }

  /// Writes [text] raw text to the current innermost [TextPiece]. Starts a new
  /// one if needed.
  ///
  /// If [text] internally contains a newline, then [containsNewline] should
  /// be `true`.
  void write(String text,
      {bool containsNewline = false, bool following = false}) {
    var textPiece = _currentText;

    // Create a new text piece if we don't have one or we are after a split.
    // Ignore the split if the text is deliberately intended to follow the
    // current text.
    if (textPiece == null || _pendingSplit && !following) {
      textPiece = _currentText = TextPiece();
    } else if (_pendingNewline) {
      textPiece.newline();
    } else if (_pendingSpace) {
      textPiece.append(' ');
    }

    textPiece.append(text, containsNewline: containsNewline);

    _pendingSpace = false;
    _pendingNewline = false;
    if (!following) _pendingSplit = false;
  }

  /// Writes a mandatory newline from a comment in the current [TextPiece].
  void writeNewline() {
    _pendingNewline = true;
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode finish() {
    var formatter = Solver(_formatter.pageWidth);

    var piece = pop();

    if (debug.tracePieceBuilder) {
      print(debug.pieceTree(piece));
    }

    var result = formatter.format(piece);

    // Be a good citizen, end with a newline.
    if (_source.isCompilationUnit) result += _formatter.lineEnding!;

    return SourceCode(result,
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        // TODO(new-ir): Update selection.
        selectionStart: null,
        selectionLength: null);
  }
}
