// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../back_end/code_writer.dart';
import '../back_end/solution_cache.dart';
import '../back_end/solver.dart';
import '../dart_formatter.dart';
import '../debug.dart' as debug;
import '../piece/adjacent.dart';
import '../piece/leading_comment.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/text.dart';
import '../profile.dart';
import '../source_code.dart';
import 'comment_writer.dart';
import 'delimited_list_builder.dart';
import 'piece_factory.dart';
import 'sequence_builder.dart';

/// Builds [TextPiece]s for [Token]s and comments.
///
/// Handles updating selection markers and attaching comments to the tokens
/// before and after the comments.
final class PieceWriter {
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

  /// The stack of pieces being built by calls to [build()].
  ///
  /// Each call to [build()] pushes a new list onto this stack. All of the
  /// pieces written during that call to [build()] end up in that list. When
  /// the [build()] callback returns, the topmost list is popped and the result
  /// returned as an [AdjacentPiece] (or just the single piece if there is
  /// only one).
  final List<List<Piece>> _pieces = [];

  /// The last piece in [_elements], if it's a [CodePiece] that can have more
  /// code appended to it or `null` if there is no trailing element or the
  /// trailing piece can't be appended to.
  CodePiece? _currentCode;

  /// If [space()] has been called and we haven't appended a space to the
  /// previous code or adding a [SpacePiece] yet.
  bool _pendingSpace = false;

  PieceWriter(this._formatter, this._source, this._comments);

  /// Wires the [PieceWriter] to the [AstNodeVisitor] (which implements
  /// [PieceFactory]) so that [PieceWriter] can visit nodes.
  void bindVisitor(PieceFactory visitor) {
    _visitor = visitor;
  }

  late final PieceFactory _visitor;

  /// Writes [token] to the piece currently being written.
  ///
  /// Does nothing if [token] is `null`. If [spaceBefore] is `true`, writes a
  /// space before the token, likewise with [spaceAfter].
  void token(Token? token,
      {bool spaceBefore = false, bool spaceAfter = false}) {
    if (token == null) return;

    if (spaceBefore) space();

    // TODO(rnystrom): If [_currentCode] is `null` but [_pendingSpace] is
    // `true`, it should be possible to create a new code piece and write the
    // leading space to it instead of having a leading SpacePiece.
    // Unfortunately, that sometimes leads to duplicate spaces in the output,
    // so it might take some tweaking to get working.

    if (token.precedingComments != null) {
      // Don't append to the previous token if there is a comment after it.
      _beginCodeToken(token);
    } else if (_currentCode case var code?) {
      // Append to the current code piece.
      if (_pendingSpace) {
        code.append(' ');
        _pendingSpace = false;
      }

      _write(code, token.lexeme, token.offset);
    } else {
      _beginCodeToken(token);
    }

    if (spaceAfter) space();
  }

  /// Writes [token], which may contain internal newlines.
  void multilineToken(Token token) {
    var comments = _comments.commentsBefore(token);

    var piece = CodePiece(_splitComments(comments, token));
    _write(piece, token.lexeme, token.offset, multiline: true);

    // Remember it so we can attach hanging comments later.
    _previousCode = piece;

    // Multiline tokens are always their own pieces.
    add(piece);
  }

  /// Visits [node] if not `null` and writes the result.
  void visit(AstNode? node,
      {bool spaceBefore = false,
      bool spaceAfter = false,
      NodeContext context = NodeContext.none}) {
    if (node == null) return;

    if (spaceBefore) space();
    _visitor.visitNode(node, context);
    if (spaceAfter) space();
  }

  /// Appends a space before the previous code being written and the next.
  void space() {
    _pendingSpace = true;
  }

  /// Writes an optional modifier that precedes other code.
  void modifier(Token? keyword) {
    token(keyword, spaceAfter: true);
  }

  /// Adds [piece] to the current piece being built.
  void add(Piece piece) {
    _flushSpace();
    _pieces.last.add(piece);
    _currentCode = null;
  }

  /// Creates a returns a new piece.
  ///
  /// Invokes [buildCallback]. All tokens and AST nodes written during that
  /// callback are collected into the returned piece.
  ///
  /// If [metadata] is non-empty, then wraps the resulting piece in another
  /// piece beginning with that metadata. If [inlineMetadata] is `true`, then
  /// the metadata is allowed to stay on the same line as the content.
  /// Otherwise, a newline is inserted after every annotation.
  Piece build(void Function() buildCallback,
      {List<Annotation> metadata = const [], bool inlineMetadata = false}) {
    _flushSpace();
    _currentCode = null;

    var leadingPieces = const <Piece>[];
    if (metadata.isNotEmpty) {
      leadingPieces = [
        for (var annotation in metadata) _visitor.nodePiece(annotation)
      ];

      // If there are comments between the metadata and declaration, then hoist
      // them out too so they don't get embedded inside the beginning piece of
      // the declaration. [SequenceBuilder] handles that for most comments
      // preceding a declaration but won't see these ones because they come
      // after the metadata.
      leadingPieces.addAll(takeCommentsBefore(metadata.last.endToken.next!));
    }

    _pieces.add([]);

    buildCallback();

    _flushSpace();
    _currentCode = null;

    var builtPieces = _pieces.removeLast();
    assert(builtPieces.isNotEmpty);

    var builtPiece = builtPieces.length == 1
        ? builtPieces.first
        : AdjacentPiece(builtPieces);

    if (leadingPieces.isEmpty) {
      // No metadata, so return the content piece directly.
      return builtPiece;
    } else if (inlineMetadata) {
      // Wrap the metadata and content in a splittable list.
      var list = DelimitedListBuilder(
          _visitor,
          const ListStyle(
            commas: Commas.none,
            spaceWhenUnsplit: true,
          ));

      for (var piece in leadingPieces) {
        list.add(piece);
      }

      list.add(builtPiece);
      return list.build();
    } else {
      // Wrap the metadata and content in a sequence.
      var sequence = SequenceBuilder(_visitor);
      for (var piece in leadingPieces) {
        sequence.add(piece);
      }

      sequence.add(builtPiece);
      return sequence.build(forceSplit: true);
    }
  }

  /// Creates a separate piece for [token], including any comments that should
  /// be attached to that token.
  ///
  /// If [discardedToken] is given, it is a token immediately before [token]
  /// that is going to be discarded. Passing it in here ensures any comments
  /// before it are preserved.
  ///
  /// If [commaAfter] is `true`, looks for and writes a comma following the
  /// token if there is one.
  Piece tokenPiece(Token token,
      {Token? discardedToken, bool commaAfter = false}) {
    var tokenPiece = _makeCodePiece(discardedToken: discardedToken, token);

    if (commaAfter) {
      var nextToken = token.next!;
      if (nextToken.lexeme == ',') {
        return AdjacentPiece([tokenPiece, _makeCodePiece(nextToken)]);
      }
    }

    return tokenPiece;
  }

  /// Writes [metadata] followed by the code written by [buildCallback].
  ///
  /// If [metadata] is empty, then invokes [buildCallback] directly. Otherwise,
  /// creates a new [Piece] that contains the pieces written from [metadata]
  /// followed by the code written by [buildCallback].
  void withMetadata(List<Annotation> metadata, void Function() buildCallback,
      {bool inlineMetadata = false}) {
    // If there's no metadata (the common case), then call the callback
    // directly instead of creating a separate AdjacentBuilder. That way, we
    // avoid splitting pieces at the boundary here if not needed.
    if (metadata.isEmpty) {
      buildCallback();
    } else {
      add(build(buildCallback,
          metadata: metadata, inlineMetadata: inlineMetadata));
    }
  }

  /// Creates a new [Piece] for [comment] and returns it.
  Piece commentPiece(SourceComment comment,
      [Whitespace trailingWhitespace = Whitespace.none]) {
    var piece = switch (comment.text) {
      '// dart format off' => EnableFormattingCommentPiece(
          enable: false,
          comment.offset + comment.text.length,
          trailingWhitespace),
      '// dart format on' => EnableFormattingCommentPiece(
          enable: true,
          comment.offset + comment.text.length,
          trailingWhitespace),
      _ => CommentPiece(trailingWhitespace),
    };

    _write(piece, comment.text, comment.offset,
        multiline: comment.type.mayBeMultiline);
    return piece;
  }

  /// Applies any hanging comments before [token] to the preceding [CodePiece]
  /// and takes and returns any remaining leading comments.
  List<Piece> takeCommentsBefore(Token token) {
    return _splitComments(_comments.takeCommentsBefore(token), token);
  }

  /// Takes any comments preceding [firstToken] and wraps them around the piece
  /// generated by [buildCallback].
  ///
  /// For comments preceding a single AST node, this hoisting is handled
  /// automatically. But there are some places in the language where there is
  /// a conceptual piece of syntax that we want to hoist the comments out of
  /// so that the syntax doesn't split but there isn't actually a single AST
  /// node associated with that syntax.
  ///
  /// This method lets you hoist comments before an arbitary amount of syntax
  /// visited and built by calling [buildCallback].
  void hoistLeadingComments(Token firstToken, Piece Function() buildCallback) {
    var leadingComments = takeCommentsBefore(firstToken);

    var piece = buildCallback();
    if (leadingComments.isNotEmpty) {
      piece = LeadingCommentPiece(leadingComments, piece);
    }

    add(piece);
  }

  /// Begins a new [CodeToken] that can potentially have more code written to
  /// it.
  void _beginCodeToken(Token token) {
    _flushSpace();
    var code = _makeCodePiece(token);
    _pieces.last.add(code);
    _currentCode = code;
  }

  /// Outputs any pending space before more code is written or the current
  /// piece is completed.
  void _flushSpace() {
    if (!_pendingSpace) return;

    _pieces.last.add(SpacePiece());
    _pendingSpace = false;
  }

  /// Creates a [CodePiece] for [token] and handles any comments that precede
  /// it, which get attached either as hanging comments on the preceding
  /// [CodePiece] or leading comments on this one.
  ///
  /// If [discardedToken] is given, it is a token immediately before [token]
  /// that is going to be discarded. Passing it in here ensures any comments
  /// before it are preserved.
  CodePiece _makeCodePiece(Token token, {Token? discardedToken}) {
    var comments = _comments.commentsBefore(token);

    // Include any comments on the preceding discarded token, if there is one.
    if (discardedToken != null) {
      comments = _comments.commentsBefore(discardedToken).concatenate(comments);
    }

    var piece = CodePiece(_splitComments(comments, token));
    _write(piece, token.lexeme, token.offset);

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
  ///
  /// If there is a `// dart format width=123` comment before the formatted
  /// code, then [pageWidthFromComment] is that width.
  SourceCode finish(
      SourceCode source, Piece rootPiece, int? pageWidthFromComment) {
    if (debug.tracePieceBuilder) {
      debug.log(debug.pieceTree(rootPiece));
    }

    Profile.begin('PieceWriter.finish() format piece tree');

    var cache = SolutionCache();
    var solver = Solver(cache,
        pageWidth: pageWidthFromComment ?? _formatter.pageWidth,
        leadingIndent: _formatter.indent);
    var solution = solver.format(rootPiece);
    var output = solution.code.build(source, _formatter.lineEnding);

    Profile.end('PieceWriter.finish() format piece tree');

    return output;
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
