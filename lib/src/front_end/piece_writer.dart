// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/token.dart';

import '../back_end/solution_cache.dart';
import '../back_end/solver.dart';
import '../dart_formatter.dart';
import '../debug.dart' as debug;
import '../piece/adjacent.dart';
import '../piece/piece.dart';
import '../source_code.dart';
import 'comment_writer.dart';

/// RegExp that matches any valid Dart line terminator.
final _lineTerminatorPattern = RegExp(r'\r\n?|\n');

/// Builds [TextPiece]s for [Token]s and comments.
///
/// Handles updating selection markers and attaching comments to the tokens
/// before and after the comments.
class PieceWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  final CommentWriter _comments;

  /// The current [TextPiece] being written to.
  TextPiece _currentText = TextPiece();

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
  /// If [lexeme] is given, uses that for the token's lexeme instead of its own.
  ///
  /// If [commaAfter] is `true`, will look for and write a comma following the
  /// token if there is one.
  Piece tokenPiece(Token token, {String? lexeme, bool commaAfter = false}) {
    _writeToken(token, lexeme: lexeme);
    var tokenPiece = _currentText;

    if (commaAfter) {
      var nextToken = token.next!;
      if (nextToken.lexeme == ',') {
        _writeToken(nextToken);
        return AdjacentPiece([tokenPiece, _currentText]);
      }
    }

    return tokenPiece;
  }

  /// Creates a piece for a simple or interpolated string [literal].
  ///
  /// Handles splitting it into multiple lines in the resulting [TextPiece] if
  /// [isMultiline] is `true`.
  Piece stringLiteralPiece(Token literal, {required bool isMultiline}) {
    if (!isMultiline) return tokenPiece(literal);

    if (!_writeCommentsBefore(literal)) {
      // We want this token to be in its own TextPiece, so if the comments
      // didn't already lead to ending the previous TextPiece than do so now.
      _currentText = TextPiece();
    }

    return _writeMultiLine(literal.lexeme, offset: literal.offset);
  }

  // TODO(tall): Much of the comment handling code in CommentWriter got moved
  // into here, so there isn't great separation of concerns anymore. Can we
  // organize this code better? Or just combine CommentWriter with this class
  // completely?

  /// Writes any comments before [token].
  ///
  /// Used to ensure comments before a token which will be discarded aren't
  /// lost.
  ///
  /// If there are any comments before [token] that should end up in their own
  /// piece, returns a piece for them.
  Piece? writeCommentsBefore(Token token) {
    // If we created a new piece while writing the comments, make sure it
    // doesn't get lost.
    if (_writeCommentsBefore(token)) return _currentText;

    // Otherwise, there are no comments, or all comments are hanging off the
    // previous TextPiece.
    return null;
  }

  /// Writes [comment] to a new [Piece] and returns it.
  Piece writeComment(SourceComment comment) {
    _currentText = TextPiece();

    return _writeMultiLine(comment.text, offset: comment.offset);
  }

  /// Writes all of the comments that appear between [token] and the previous
  /// one.
  ///
  /// Any hanging comments will be written to the current [TextPiece] for the
  /// previous token. Remaining comments are written to a new [TextPiece].
  /// Returns `true` if it created a new [TextPiece].
  bool _writeCommentsBefore(Token token) {
    var comments = _comments.commentsBefore(token);
    if (comments.isEmpty) return false;

    var createdPiece = false;

    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      // The whitespace between the previous code or comment and this one.
      if (comments.isHanging(i)) {
        // Write a space before hanging comments.
        _currentText.space();
      } else if (!createdPiece) {
        // The previous piece must end in a newline before this comment.
        _currentText.newline();

        // Only split once between the last hanging comment and the remaining
        // non-hanging ones. Otherwise, we would end up dropping comment pieces
        // on the floor. So given:
        //
        //     before + // one
        //        // two
        //        // three
        //        // four
        //        after;
        //
        // The pieces are:
        //
        // - `before + // one`
        // - `// two¬// three¬// four¬after`
        // - `;`
        _currentText = TextPiece();
        createdPiece = true;
      } else {
        // There are multiple comments before the token that each need to be on
        // their own lines, so split between the previous one and this one.
        _currentText.newline();
      }

      _write(comment.text, offset: comment.offset);
    }

    // Output a trailing newline after the last comment if it needs one.
    if (comments.last.requiresNewline) {
      _currentText.newline();
    } else if (_needsSpaceAfterComment(token.lexeme)) {
      _currentText.space();
    }

    return createdPiece;
  }

  /// Returns `true` if a space should be output after an inline comment
  /// which is followed by [lexeme].
  bool _needsSpaceAfterComment(String lexeme) {
    // It gets a space unless the next token is a delimiting punctuation.
    return lexeme != ')' &&
        lexeme != ']' &&
        lexeme != '}' &&
        lexeme != ',' &&
        lexeme != ';';
  }

  /// Writes [token] and any comments that precede it to the current [TextPiece]
  /// and updates any selection markers that appear in it.
  void _writeToken(Token token, {String? lexeme}) {
    if (!_writeCommentsBefore(token)) {
      // We want this token to be in its own TextPiece, so if the comments
      // didn't already lead to ending the previous TextPiece than do so now.
      _currentText = TextPiece();
    }

    lexeme ??= token.lexeme;

    _write(lexeme, offset: token.offset);
  }

  /// Writes multi-line [text] to the current [TextPiece].
  ///
  /// Handles breaking [text] into lines and adding them to the [TextPiece].
  ///
  /// The [offset] parameter is the offset in the original source code of the
  /// beginning of multi-line lexeme.
  Piece _writeMultiLine(String text, {required int offset}) {
    var lines = text.split(_lineTerminatorPattern);
    var currentOffset = offset;
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) _currentText.newline(flushLeft: true);
      _write(lines[i], offset: currentOffset);
      currentOffset += lines[i].length;
    }

    return _currentText;
  }

  /// Writes [text] to the current [TextPiece].
  ///
  /// If [offset] is given and it contains any selection markers, then attaches
  /// those markers to the [TextPiece].
  void _write(String text, {int? offset}) {
    if (offset != null) {
      // If this text contains any of the selection endpoints, note their
      // relative locations in the text piece.
      if (_findSelectionStartWithin(offset, text.length) case var start?) {
        _currentText.startSelection(start);
      }

      if (_findSelectionEndWithin(offset, text.length) case var end?) {
        _currentText.endSelection(end);
      }
    }

    _currentText.append(text);
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode finish(Piece rootPiece) {
    if (debug.tracePieceBuilder) {
      debug.log(debug.pieceTree(rootPiece));
    }

    // See if it's possible to eagerly pin any of the pieces based just on the
    // length and newlines in their children. This is faster, especially for
    // larger outermost pieces, then relying on the solver to determine their
    // state.
    void traverse(Piece piece) {
      piece.forEachChild(traverse);

      if (piece.fixedStateForPageWidth(_formatter.pageWidth) case var state?) {
        piece.pin(state);
      }
    }

    traverse(rootPiece);

    var cache = SolutionCache();
    var formatter = Solver(cache, pageWidth: _formatter.pageWidth);
    var result = formatter.format(rootPiece);
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
