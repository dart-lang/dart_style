// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:collection';

import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../comment_type.dart';
import '../piece/sequence.dart';
import 'piece_writer.dart';

/// Functionality used by [AstNodeVisitor] to build text and pieces from the
/// comment tokens between meaningful tokens used by AST nodes.
///
/// Also handles preserving discretionary blank lines in places where they are
/// allowed. These are handled with comments because both comments and
/// whitespace are found between the linear series of [Token]s produced by the
/// analyzer parser. Likewise, both are output as whitespace (in the sense of
/// not being executable code) interleaved with the [Piece]-building code that
/// walks the actual AST and processes the code tokens.
///
/// Comments are a challenge because they confound the intuitive tree-like
/// structure of the code. A comment can appear between any two tokens, and a
/// line comment can force the formatter to insert a newline in places where
/// one wouldn't otherwise make sense. When that happens, the formatter then
/// has to decide how to indent the next line.
///
/// To deal with that, there are two styles or ways that comments are handled:
///
/// ### Sequence comments
///
/// Most comments appear around statements in a block, members in a class, or
/// at the top level of a file. At the point the comment appears, the formatter
/// is in the middle of building a [SequencePiece]. For those, [CommentWriter]
/// treats the comments almost like their own statements or members and inserts
/// them into the surrounding sequence as their own separate pieces.
///
/// Sequences already support allowing discretionary blank lines between child
/// pieces, so this lets us use that same functionality to control blank lines
/// between comments as well.
///
/// ### Non-sequence comments
///
/// All other comments occur inside the middle of some expression or other
/// construct. These get directly embedded in the [TextPiece] of the code being
/// written. When that [TextPiece] is output later, it will include the comments
/// as well.
mixin CommentWriter {
  PieceWriter get writer;

  LineInfo get lineInfo;

  /// If the next token written is the first token in a sequence element, this
  /// will be that sequence.
  SequencePiece? _pendingSequence;

  /// Call this before visiting an AST node that will become a piece in a
  /// [SequencePiece].
  void beforeSequenceNode(SequencePiece sequence) {
    _pendingSequence = sequence;
  }

  /// Writes comments that appear before [token].
  void writeCommentsAndBlanksBefore(Token token) {
    if (_pendingSequence case var sequence?) {
      _pendingSequence = null;
      _writeSequenceComments(sequence, token);
    } else {
      _writeNonSequenceComments(token);
    }
  }

  /// Writes [comments] to [sequence].
  ///
  /// This is used when the token is the first token in a node inside a
  /// sequence. In that case, any comments that belong on their own line go as
  /// separate elements in the sequence. This lets the sequence handle blank
  /// lines before and/or after them.
  void _writeSequenceComments(SequencePiece sequence, Token token) {
    var comments = _collectComments(token);

    // Edge case: if we require a blank line, but there exists one between
    // some of the comments, or after the last one, then we don't need to
    // enforce one before the first comment. Example:
    //
    //     library foo;
    //     // comment
    //
    //     class Bar {}
    //
    // Normally, a blank line is required after `library`, but since there is
    // one after the comment, we don't need one before it. This is mainly so
    // that commented out directives stick with their preceding group.
    if (comments.containsBlank) {
      sequence.removeBlank();
    }

    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];
      if (sequence.contents.isNotEmpty && comments.isHanging(i)) {
        // Attach the comment to the previous token.
        writer.space();

        writer.writeComment(comment, following: true);
      } else {
        // Write the comment as its own sequence piece.
        writer.writeComment(comment);
        if (comments.linesBefore(i) > 1) sequence.addBlank();
        sequence.add(writer.pop());
        writer.split();
      }
    }

    // Write a blank before the token if there should be one.
    if (comments.linesBeforeNextToken > 1) sequence.addBlank();
  }

  /// Writes comments before [token] when [token] is not the first element in
  /// a sequence.
  ///
  /// In that case, the comments are directly embedded in the [TextPiece]s for
  /// the preceding token and/or [token].
  void _writeNonSequenceComments(Token token) {
    // In the common case where there are no comments before the token, early
    // out. This avoids calculating the number of newlines between every pair
    // of tokens which is slow and unnecessary.
    if (token.precedingComments == null) return;

    var comments = _collectComments(token);

    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      if (comments.isHanging(i)) {
        // Attach the comment to the previous token.
        writer.space();
        writer.writeComment(comment, following: true);
      } else {
        writer.writeNewline();
        writer.writeComment(comment);
      }

      if (comment.type == CommentType.line) writer.writeNewline();
    }

    if (comments.isNotEmpty && _needsSpaceAfterComment(token.lexeme)) {
      writer.space();
    }
  }

  /// Takes all of the comment tokens preceding [token] and builds a
  /// [CommentSequence] that tracks them and the whitespace between them.
  CommentSequence _collectComments(Token token) {
    var previousLine = _endLine(token.previous!);
    var tokenLine = _startLine(token);

    // Edge case: The analyzer includes the "\n" in the script tag's lexeme,
    // which confuses some of these calculations. We don't want to allow a
    // blank line between the script tag and a following comment anyway, so
    // just override the script tag's line.
    if (token.previous!.type == TokenType.SCRIPT_TAG) previousLine = tokenLine;

    var comments = CommentSequence();
    for (Token? comment = token.precedingComments;
        comment != null;
        comment = comment.next) {
      var commentLine = _startLine(comment);

      var text = comment.lexeme.trim();
      var linesBefore = commentLine - previousLine;
      var flushLeft = _startColumn(comment) == 1;

      if (text.startsWith('///') && !text.startsWith('////')) {
        // Line doc comments are always indented even if they were flush left.
        flushLeft = false;

        // Always add a blank line (if possible) before a doc comment block.
        if (comment == token.precedingComments) linesBefore = 2;
      }

      CommentType type;
      if (text.startsWith('///') && !text.startsWith('////') ||
          text.startsWith('/**') && text != '/**/') {
        type = CommentType.doc;
      } else if (comment.type == TokenType.SINGLE_LINE_COMMENT) {
        type = CommentType.line;
      } else if (commentLine == previousLine || commentLine == tokenLine) {
        type = CommentType.inlineBlock;
      } else {
        type = CommentType.block;
      }

      var sourceComment = SourceComment(text, type, flushLeft: flushLeft);

      // TODO(tall): If this comment contains either of the selection endpoints,
      // mark them in the comment.

      comments._add(linesBefore, sourceComment);

      previousLine = _endLine(comment);
    }

    comments._setLinesBeforeNextToken(tokenLine - previousLine);
    return comments;
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the [token] that will be written.
  bool _needsSpaceAfterComment(String token) {
    // It gets a space if the following token is not a delimiter or the empty
    // string (for EOF).
    return token != ')' &&
        token != ']' &&
        token != '}' &&
        token != ',' &&
        token != ';' &&
        token != '';
  }

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      lineInfo.getLocation(token.offset).columnNumber;
}

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
class SourceComment {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  final String text;

  final CommentType type;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool flushLeft;

  SourceComment(this.text, this.type, {required this.flushLeft});

  /// Whether this comment contains a mandatory newline, either because it's a
  /// line comment or a multi-line block comment.
  bool get containsNewline => type == CommentType.line || text.contains('\n');
}

/// A list of source code comments and the number of newlines between them, as
/// well as the number of newlines before the first comment and after the last
/// comment.
///
/// If there are no comments, this just tracks the number of newlines between
/// a pair of tokens.
///
/// This class is not simply a list of "comment + newline" pairs because we want
/// to know the number of newlines before the first comment and after the last.
/// That means there is always one more newline count that there are comments,
/// including the degenerate case where there are no comments but one newline
/// count.
///
/// For example, this code:
///
/// ```dart
/// a /* c1 */
/// /* c2 */
///
/// /* c3 */
///
///
/// b
/// ```
///
/// Produces a sequence like:
///
/// * 0 newlines between `a` and `/* c1 */`
/// * Comment `/* c1 */`
/// * 1 newline between `/* c1 */` and `/* c2 */`
/// * Comment `/* c2 */`
/// * 2 newlines between `/* c2 */` and `/* c3 */`
/// * Comment `/* c3 */`
/// * 3 newlines between `/* c3 */` and `b`
/// ```
class CommentSequence extends ListBase<SourceComment> {
  /// The number of newlines between a pair of comments or the preceding or
  /// following tokens.
  ///
  /// This list is always one element longer than [_comments].
  final List<int> _linesBetween = [];

  final List<SourceComment> _comments = [];

  /// The number of newlines between the comment at [commentIndex] and the
  /// preceding comment or token.
  int linesBefore(int commentIndex) => _linesBetween[commentIndex];

  /// The number of newlines between the comment at [commentIndex] and the
  /// following comment or token.
  int linesAfter(int commentIndex) => _linesBetween[commentIndex + 1];

  /// Whether the comment at [commentIndex] should be attached to the preceding
  /// token.
  bool isHanging(int commentIndex) {
    // Don't move a comment to a preceding line.
    if (linesBefore(commentIndex) != 0) return false;

    // Doc comments and non-inline `/* ... */` comments are always pushed to
    // the next line.
    var type = _comments[commentIndex].type;
    return type != CommentType.doc && type != CommentType.block;
  }

  /// The number of newlines between the last comment and the next token.
  ///
  /// If there are no comments, this is the number of lines between the next
  /// token and the preceding one.
  int get linesBeforeNextToken => _linesBetween.last;

  /// Whether there are any blank lines (i.e. more than one newline) between any
  /// pair of comments or between the comments and surrounding code.
  bool get containsBlank => _linesBetween.any((lines) => lines > 1);

  /// The number of comments in the sequence.
  @override
  int get length => _comments.length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Comment sequence can\'t be modified.');

  /// The comment at [index].
  @override
  SourceComment operator [](int index) => _comments[index];

  @override
  operator []=(int index, SourceComment value) =>
      throw UnsupportedError('Comment sequence can\'t be modified.');

  void _add(int linesBefore, SourceComment comment) {
    _linesBetween.add(linesBefore);
    _comments.add(comment);
  }

  /// Records the number of lines between the end of the last comment and the
  /// beginning of the next token.
  void _setLinesBeforeNextToken(int linesAfter) {
    _linesBetween.add(linesAfter);
  }
}
