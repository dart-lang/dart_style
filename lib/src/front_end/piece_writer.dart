// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/solver.dart';
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
/// for the expression statement and instead, the `;` is just appended to the
/// trailing TextPiece which may be deeply nested inside the binary expression.
///
/// This class implements the "slippage" between these two representations. It
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
/// composing those pieces is [split()], [push()], and [pop()].
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
///   // Call pop() instead of split() because there may not be an else branch.
///   // If there isn't, then the thenBranch will be the trailing piece created
///   // by this function and we want to allow the caller to append to its
///   // innermost TextPiece.
///   var thenPiece = pieces.pop();
///
///   Piece? elsePiece;
///   if (node.elseBranch case var elseBranch?) {
///     // Call split() here because it turns out we do have something after
///     // the thenPiece and we want to be able to split between the then and
///     // else parts.
///     pieces.split();
///     visit(elseBranch);
///
///     // Use pop() to capture the else branch while allowing the caller to
///     // append more code to it.
///     elsePiece = pieces.pop();
///   }
///
///   // Create a new aggregate piece out of the subpieces and allow the caller
///   // to get it.
///   pieces.push(IfPiece(conditionPiece, thenPiece, elsePiece));
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
/// -   Use [pop()] to capture the current piece while allowing further code to
///     be appended to it. You'll usually call this to grab the last part of an
///     AST node where there is no more subsequent code.
///
/// -   Use [push()] to return the newly created aggregate piece so that the
///     caller can capture it with a later call to [split()] or [pop()].
class PieceWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  /// The current [TextPiece] being written to or `null` if no text piece has
  /// been started yet.
  TextPiece? get currentText => _currentText;
  TextPiece? _currentText;

  /// The most recently pushed piece, waiting to be taken by some surrounding
  /// piece.
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
  /// to [pop()] or [split()] from some surrounding piece.
  void push(Piece piece) {
    // Should never push more than one piece.
    assert(_pushed == null);
    _pushed = piece;
  }

  /// Yields the most recent piece.
  ///
  /// If a completed piece was added through a call to [push()], then returns
  /// that piece. A pushed piece will only be returned once from either a call
  /// to [pop()] or [split()].
  ///
  /// If there is no pushed piece to return, returns the most recently created
  /// [TextPiece]. In this case, it still allows more text to be written to
  /// that piece. For example, in:
  ///
  /// ```
  /// a + b;
  /// ```
  ///
  /// The code for the infix expression will call [pop()] to capture the second
  /// `b` operand. Then the surrounding code for the expression statement will
  /// call [token()] for the `;`, which will correctly append it to the
  /// [TextPiece] for `b`.
  Piece pop() {
    if (_pushed case var piece?) {
      _pushed = null;
      return piece;
    }

    return _currentText!;
  }

  /// Pops the most recent piece and begins a new one.
  ///
  /// Any text written after this will go into a new [TextPiece] instead of
  /// being appended to the end of the popped one. Call this wherever a line
  /// break may be inserted by a piece during line splitting.
  Piece split() {
    _pendingSplit = true;
    return pop();
  }

  /// Writes [text] raw text to the current innermost [TextPiece]. Starts a new
  /// one if needed.
  void write(String text) {
    _write(text);
  }

  /// Writes a space to the current [TextPiece].
  void writeSpace() {
    _pendingSpace = true;
  }

  /// Writes a mandatory newline from a comment to the current [TextPiece].
  void writeNewline() {
    _pendingNewline = true;
  }

  /// Write the contents of [comment] to the current innnermost [TextPiece],
  /// handling any newlines that may appear in it.
  ///
  /// If [hanging] is `true`, then the comment is appended to the current line
  /// even if call to [split()] has just happened. This is used for writing a
  /// comment that should be on the end of a line.
  void writeComment(SourceComment comment, {bool hanging = false}) {
    _write(comment.text,
        containsNewline: comment.containsNewline, hanging: hanging);
  }

  void _write(String text,
      {bool containsNewline = false, bool hanging = false}) {
    var textPiece = _currentText;

    // Create a new text piece if we don't have one or we are after a split.
    // Ignore the split if the text is deliberately intended to follow the
    // current text.
    if (textPiece == null || _pendingSplit && !hanging) {
      textPiece = _currentText = TextPiece();
    } else if (_pendingNewline) {
      textPiece.newline();
    } else if (_pendingSpace) {
      textPiece.append(' ');
    }

    textPiece.append(text, containsNewline: containsNewline);

    _pendingSpace = false;
    _pendingNewline = false;
    if (!hanging) _pendingSplit = false;
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
