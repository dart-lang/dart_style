// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/token.dart';

import '../back_end/solver.dart';
import '../comment_type.dart';
import '../dart_formatter.dart';
import '../debug.dart' as debug;
import '../piece/piece.dart';
import '../source_code.dart';
import 'comment_writer.dart';

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
/// happens to just be an identifier but could be a more complex piece if the
/// left operand was a nested expression). Notice also that there is no piece
/// for the expression statement and, instead, the `;` is just appended to the
/// trailing TextPiece which may be deeply nested inside the binary expression.
///
/// This class implements that "slippage" between the two representations. It
/// has mutable state to allow incrementally building up pieces while traversing
/// the source AST nodes.
///
/// To visit an AST node and translate it to pieces, call [token()] and
/// [visit()] to process the individual tokens and subnodes of the current
/// node. Those will ultimately bottom out on calls to [write()], which appends
/// literal text to the current [TextPiece] being written.
///
/// Those [TextPiece]s are aggregated into a tree of composite pieces which
/// break the code into separate sections for line splitting. The main API for
/// composing those pieces is [split()], [give()], and [take()].
///
/// Here is a simplified example of how they work:
///
/// ```
/// visitIfStatement(IfStatement node) {
///   // No split() here. The caller may have code they want to prepend to the
///   // first piece in this one.
///   visit(node.condition);
///
///   // Call split() because we may want to split between the condition and
///   // then branches and we know there will be a then branch.
///   var conditionPiece = pieces.split();
///
///   visit(node.thenBranch);
///   // Call take() instead of split() because there may not be an else branch.
///   // If there isn't, then the thenBranch will be the trailing piece created
///   // by this function and we want to allow the caller to append to its
///   // innermost TextPiece.
///   var thenPiece = pieces.take();
///
///   Piece? elsePiece;
///   if (node.elseBranch case var elseBranch?) {
///     // Call split() here because it turns out we do have something after
///     // the thenPiece and we want to be able to split between the then and
///     // else parts.
///     pieces.split();
///     visit(elseBranch);
///
///     // Use take() to capture the else branch while allowing the caller to
///     // append more code to it.
///     elsePiece = pieces.take();
///   }
///
///   // Create a new aggregate piece out of the subpieces and allow the caller
///   // to get it.
///   pieces.give(IfPiece(conditionPiece, thenPiece, elsePiece));
/// }
/// ```
///
/// The basic rules are:
///
/// -   Use [split()] to insert a point where a line break can occur and
///     capture the piece for the code you've just written. You'll usually call
///     this when you have already traversed some part of an AST node and have
///     more to traverse after it.
///
/// -   Use [take()] to capture the current piece while allowing further code to
///     be appended to it. You'll usually call this to grab the last part of an
///     AST node where there is no more subsequent code.
///
/// -   Use [give()] to return the newly created aggregate piece so that the
///     caller can capture it with a later call to [split()] or [take()].
class PieceWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  /// The current [TextPiece] being written to or `null` if no text piece has
  /// been started yet.
  TextPiece? get currentText => _currentText;
  TextPiece? _currentText;

  /// The most recently given piece, waiting to be taken by some surrounding
  /// piece.
  Piece? _given;

  /// Whether we should write a space before the next text that is written.
  bool _pendingSpace = false;

  /// Whether we should create a new [TextPiece] the next time text is written.
  bool _pendingSplit = false;

  /// Whether we have reached a token or comment that lies at or beyond the
  /// selection start offset in the original code.
  ///
  /// Makes sure we insert the start marker in some piece even if it happens to
  /// lie between two tokens in the input.
  bool _passedSelectionStart = false;

  /// Whether we have reached a token or comment that lies at or beyond the
  /// selection end offset in the original code.
  ///
  /// Makes sure we insert the end marker in some piece even if it happens to
  /// lie between two tokens in the input.
  bool _passedSelectionEnd = false;

  /// The character offset of the end of the selection with any trailing
  /// whitespace removed.
  ///
  /// This can only be accessed if there is a selection.
  late final int _selectionEnd = _findSelectionEnd();

  PieceWriter(this._formatter, this._source);

  /// Gives the builder a newly completed [piece], to be taken by a later call
  /// to [take()] or [split()] from some surrounding piece.
  void give(Piece piece) {
    // Any previously given piece should already be taken (and used as a child
    // of [piece]).
    assert(_given == null);
    _given = piece;
  }

  /// Yields the most recent piece.
  ///
  /// If a completed piece was added through a call to [give()], then returns
  /// that piece. A specific given piece will only be returned once from either
  /// a call to [take()] or [split()].
  ///
  /// If there is no given piece to return, returns the most recently created
  /// [TextPiece]. In this case, it still allows more text to be written to
  /// that piece. For example, in:
  ///
  /// ```
  /// a + b;
  /// ```
  ///
  /// The code for the infix expression will call [take()] to capture the second
  /// `b` operand. Then the surrounding code for the expression statement will
  /// call [token()] for the `;`, which will correctly append it to the
  /// [TextPiece] for `b`.
  Piece take() {
    if (_given case var piece?) {
      _given = null;
      return piece;
    }

    return _currentText!;
  }

  /// Takes the most recent piece and begins a new one.
  ///
  /// Any text written after this will go into a new [TextPiece] instead of
  /// being appended to the end of the taken one. Call this wherever a line
  /// break may be inserted by a piece during line splitting.
  Piece split() {
    _pendingSplit = true;
    return take();
  }

  /// Writes raw [text] to the current innermost [TextPiece]. Starts a new
  /// one if needed.
  ///
  /// If [offset] is given, it should be the number of code points preceding
  /// this [text] in the original source code.
  void writeText(String text, {int? offset}) {
    _write(text, offset: offset);
  }

  /// Writes the text of [token] to the current innermost [TextPiece], tracking
  /// any selection markers that may appear in it.
  void writeToken(Token token) {
    _write(token.lexeme, offset: token.offset);
  }

  /// Writes a space to the current [TextPiece].
  void writeSpace() {
    _pendingSpace = true;
  }

  /// Writes a mandatory newline from a comment to the current [TextPiece].
  void writeNewline() {
    _currentText!.newline();
  }

  /// Write the contents of [comment] to the current innermost [TextPiece],
  /// handling any newlines that may appear in it.
  ///
  /// If [hanging] is `true`, then the comment is appended to the current line
  /// even if a call to [split()] has happened. This is used for writing a
  /// comment that should be on the end of a line.
  void writeComment(SourceComment comment, {bool hanging = false}) {
    _write(comment.text,
        offset: comment.offset,
        containsNewline: comment.containsNewline,
        hanging: hanging);
  }

  void _write(String text,
      {bool containsNewline = false, bool hanging = false, int? offset}) {
    var textPiece = _currentText;

    // Create a new text piece if we don't have one or we are after a split.
    // Ignore the split if the text is deliberately intended to follow the
    // current text.
    if (textPiece == null || _pendingSplit && !hanging) {
      textPiece = _currentText = TextPiece();
    } else if (_pendingSpace || hanging) {
      // Always write a space before hanging comments.
      textPiece.appendSpace();
    }

    if (offset != null) {
      // If this text contains any of the selection endpoints, note their
      // relative locations in the text piece.
      if (_findSelectionStartWithin(offset, text.length) case var start?) {
        textPiece.startSelection(start);
      }

      if (_findSelectionEndWithin(offset, text.length) case var end?) {
        textPiece.endSelection(end);
      }
    }

    textPiece.append(text, containsNewline: containsNewline);

    _pendingSpace = false;
    if (!hanging) _pendingSplit = false;
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode finish() {
    var formatter = Solver(_formatter.pageWidth);

    var piece = take();

    if (debug.tracePieceBuilder) {
      print(debug.pieceTree(piece));
    }

    var result = formatter.format(piece);
    var outputCode = result.text;

    // Be a good citizen, end with a newline.
    if (_source.isCompilationUnit) outputCode += _formatter.lineEnding!;

    int? selectionStart;
    int? selectionLength;
    if (_source.selectionStart != null) {
      selectionStart = result.selectionStart;
      var selectionEnd = result.selectionEnd;

      // If we haven't hit the beginning and/or end of the selection yet, they
      // must be at the very end of the code.
      selectionStart ??= outputCode.length;
      selectionEnd ??= outputCode.length;

      selectionLength = selectionEnd - selectionStart;
    }

    return SourceCode(outputCode,
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: selectionStart,
        selectionLength: selectionLength);
  }

  /// Returns the number of characters past [position] in the source where the
  /// selection start appears if it appears within `position + length`.
  ///
  /// Returns `null` if the selection start has already been processed or is
  /// not within that range.
  int? _findSelectionStartWithin(int position, int length) {
    // If there is no selection, do nothing.
    var absoluteStart = _source.selectionStart;
    if (absoluteStart == null) return null;

    // If we've already passed it, don't consider it again.
    if (_passedSelectionStart) return null;

    // Calculate the start position relative to [offset].
    var relativeStart = absoluteStart - position;

    // If it started in whitespace before this text, push it forward to the
    // beginning of the non-whitespace text.
    if (relativeStart < 0) relativeStart = 0;

    // If we haven't reached it yet, don't consider it. If the start point is
    // right at the end of the token, don't consider that as reaching it.
    // Instead, we'll reach it on the next token, which will correctly push
    // it past any whitespace after this token and move it to the beginning of
    // the next one.
    if (relativeStart >= length) return null;

    // We found it.
    _passedSelectionStart = true;
    return relativeStart;
  }

  /// Returns the number of characters past [position] in the source where the
  /// selection endpoint appears if it appears before `position + length`.
  ///
  /// Returns `null` if the selection endpoint has already been processed or is
  /// not within that range.
  int? _findSelectionEndWithin(int position, int length) {
    // If there is no selection, do nothing.
    if (_source.selectionLength == null) return null;

    // If we've already passed it, don't consider it again.
    if (_passedSelectionEnd) return null;

    var relativeEnd = _selectionEnd - position;

    // If it started in whitespace before this text, push it forward to the
    // beginning of the non-whitespace text.
    if (relativeEnd < 0) relativeEnd = 0;

    // If we haven't reached the end point yet, don't consider it. Note that,
    // unlike [_findSelectionStartWithin], we do consider the end point being
    // right at the end of this token to be reaching it. That way, we don't
    // push the end point *past* the next span of whitespace and instead pull
    // it tight to the end of this text.
    if (relativeEnd > length) return null;

    // In [_findSelectionStartWithin], if the start marker is between two
    // tokens, we push it forward to the next one. In the above statement, we
    // push the end marker earlier to the previous token. If the entire
    // selection is in whitespace between two tokens, that would cause the
    // start and ends to cross. Prevent that and instead push the end marker
    // to the beginning of the next token where the start marker will also be
    // pushed.
    if (relativeEnd == length && _selectionEnd == _source.selectionStart!) {
      return null;
    }

    // We found it.
    _passedSelectionEnd = true;

    return relativeEnd;
  }

  /// Calculates the character offset in the source text of the end of the
  /// selection.
  ///
  /// Removes any trailing whitespace from the selection. For example, if the
  /// original selection markers are:
  ///
  /// ```
  /// function(lotsOfSpac‹eAfter,     ›     andBefore);
  /// ```
  ///
  /// Then this function moves the end marker to:
  ///
  /// ```
  /// function(lotsOfSpac‹eAfter,›          andBefore);
  /// ```
  ///
  /// We do this because the formatter itself rewrites whitespace so it's not
  /// useful or even meaningful to try to preserve a selection's location within
  /// whitespace. Instead, we "rubberband" the end marker forward to the nearest
  /// non-whitespace character.
  int _findSelectionEnd() {
    var end = _source.selectionStart! + _source.selectionLength!;

    // If the selection bumps to the end of the source, pin it there.
    if (end == _source.text.length) return end;

    // Trim off any trailing whitespace.
    while (end > _source.selectionStart!) {
      // Stop if we hit anything other than space, tab, newline or carriage
      // return.
      var char = _source.text.codeUnitAt(end - 1);
      if (char != 0x20 && char != 0x09 && char != 0x0a && char != 0x0d) {
        break;
      }

      end--;
    }

    return end;
  }
}
