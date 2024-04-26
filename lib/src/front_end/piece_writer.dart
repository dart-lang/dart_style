// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/token.dart';

import '../back_end/code_writer.dart';
import '../back_end/solution_cache.dart';
import '../back_end/solver.dart';
import '../dart_formatter.dart';
import '../debug.dart' as debug;
import '../piece/adjacent.dart';
import '../piece/piece.dart';
import '../profile.dart';
import '../source_code.dart';
import 'comment_writer.dart';

/// Builds [TextPiece]s for [Token]s and comments.
///
/// Handles updating selection markers and attaching comments to the tokens
/// before and after the comments.
class PieceWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  final CommentWriter _comments;

  /// The most recent previously-created [CodePiece].
  ///
  /// We hold a reference to this so we can attach hanging comments to it,
  /// which we don't discover until we reach the token after the one used to
  /// create this piece.
  CodePiece? _previousCode;

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

  PieceWriter(this._formatter, this._source, this._comments);

  /// Creates a piece for [token], including any comments that should be
  /// attached to that token.
  ///
  /// If [discardedToken] is given, it is a token immediately before [token]
  /// that is going to be discarded. Passing it in here ensures any comments
  /// before it are preserved.
  ///
  /// If [commaAfter] is `true`, will look for and write a comma following the
  /// token if there is one.
  Piece tokenPiece(Token token,
      {Token? discardedToken,
      bool commaAfter = false,
      bool multiline = false}) {
    var tokenPiece = _makeCodePiece(
        discardedToken: discardedToken, token, multiline: multiline);

    if (commaAfter) {
      var nextToken = token.next!;
      if (nextToken.lexeme == ',') {
        return AdjacentPiece([tokenPiece, _makeCodePiece(nextToken)]);
      }
    }

    return tokenPiece;
  }

  // TODO(tall): Much of the comment handling code in CommentWriter got moved
  // into here, so there isn't great separation of concerns anymore. Can we
  // organize this code better? Or just combine CommentWriter with this class
  // completely?

  /// Creates a new [Piece] for [comment] and returns it.
  Piece commentPiece(SourceComment comment,
      [Whitespace trailingWhitespace = Whitespace.none]) {
    var commentPiece = CommentPiece(trailingWhitespace);
    _write(commentPiece, comment.text, comment.offset, multiline: true);
    return commentPiece;
  }

  /// Applies any hanging comments before [token] to the preceding [CodePiece]
  /// and takes and returns any remaining leading comments.
  List<Piece> takeCommentsBefore(Token token) {
    return _splitComments(_comments.takeCommentsBefore(token), token);
  }

  /// Creates a [CodePiece] for [token] and handles any comments that precede
  /// it, which get attached either as hanging comments on the preceding
  /// [CodePiece] or leading comments on this one.
  ///
  /// If [discardedToken] is given, it is a token immediately before [token]
  /// that is going to be discarded. Passing it in here ensures any comments
  /// before it are preserved.
  ///
  /// If [multiline] is `true`, then [token]'s lexeme may contain internal
  /// newlines. The lexeme will be split into separate lines. If omitted, then
  /// [token] must not contain newlines.
  CodePiece _makeCodePiece(Token token,
      {Token? discardedToken, bool multiline = false}) {
    var comments = _comments.commentsBefore(token);

    // Include any comments on the preceding discarded token, if there is one.
    if (discardedToken != null) {
      comments = _comments.commentsBefore(discardedToken).concatenate(comments);
    }

    var piece = CodePiece(_splitComments(comments, token));
    _write(piece, token.lexeme, token.offset, multiline: multiline);

    // Remember it so we can attach hanging comments later.
    return _previousCode = piece;
  }

  /// Splits [comments] which precede [token] into [CommentPiece]s that hang
  /// off the preceding [CodePiece] and those that are leading comments on the
  /// [CodePiece] for [token].
  ///
  /// Attaches hanging comments to [_previousCode]. Returns the list of leading
  /// comments that should precede [token].
  List<Piece> _splitComments(CommentSequence comments, Token token) {
    if (comments.isEmpty) return const [];

    var leadingComments = <Piece>[];
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      // The whitespace after this comment before the next comment or code.
      var trailingWhitespace = switch (token.lexeme) {
        _ when comment.requiresNewline => Whitespace.newline,
        // No space between a comment and delimiting punctuation.
        ']' || '}' || ',' || ';' => Whitespace.none,
        _ => Whitespace.space,
      };

      var piece = commentPiece(comment, trailingWhitespace);

      if (comments.isHanging(i)) {
        // Attach it to the previous CodePiece.
        _previousCode!.addHangingComment(piece);
      } else {
        // Add it to the list of leading comments for the upcoming token.
        leadingComments.add(piece);
      }
    }

    return leadingComments;
  }

  /// Appends [text] to [piece] and updates any selection markers that fall
  /// within it.
  ///
  /// The [offset] parameter is the offset in the original source code of the
  /// beginning of where [text] appears.
  void _write(TextPiece piece, String text, int offset,
      {bool multiline = false}) {
    piece.append(text,
        multiline: multiline,
        selectionStart: _findSelectionStartWithin(offset, text.length),
        selectionEnd: _findSelectionEndWithin(offset, text.length));
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode finish(Piece rootPiece) {
    if (debug.tracePieceBuilder) {
      debug.log(debug.pieceTree(rootPiece));
    }

    Profile.begin('PieceWriter.finish() format piece tree');

    var cache = SolutionCache();
    var formatter = Solver(cache,
        pageWidth: _formatter.pageWidth, leadingIndent: _formatter.indent);
    var result = formatter.format(rootPiece);
    var outputCode = result.text;

    Profile.end('PieceWriter.finish() format piece tree');

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
  ///     function(lotsOfSpac‹eAfter,     ›     andBefore);
  ///
  /// Then this function moves the end marker to:
  ///
  ///     function(lotsOfSpac‹eAfter,›          andBefore);
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
