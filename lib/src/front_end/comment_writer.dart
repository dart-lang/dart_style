// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../piece/sequence.dart';
import '../source_comment.dart';
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
    var (comments, linesBeforeToken) = _convertComments(token);

    if (_pendingSequence case var sequence?) {
      _pendingSequence = null;
      _writeSequenceComments(sequence, comments, linesBeforeToken);
    } else {
      _writeNonSequenceComments(comments, linesBeforeToken, token);
    }
  }

  /// Writes [comments] to [sequence].
  ///
  /// This is used when the token is the first token in a node inside a
  /// sequence. In that case, any comments that belong on their own line go as
  /// separate elements in the sequence. This lets the sequence handle blank
  /// lines before and/or after them.
  void _writeSequenceComments(SequencePiece sequence,
      List<SourceComment> comments, int linesBeforeToken) {
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
    if (linesBeforeToken > 1 ||
        comments.any((comment) => comment.linesBefore > 1)) {
      sequence.removeBlank();
    }

    for (var comment in comments) {
      var containsNewline =
          comment.type == CommentType.line || comment.text.contains('\n');

      if (_isHangingComment(comment)) {
        // Attach the comment to the previous token.
        writer.space();
        writer.write(comment.text,
            containsNewline: containsNewline, following: true);
      } else {
        // Write the comment as its own sequence piece.
        writer.write(comment.text, containsNewline: containsNewline);
        if (comment.linesBefore > 1) sequence.addBlank();
        sequence.add(writer.pop());
        writer.split();
      }
    }

    // Write a blank before the token if there should be one.
    if (linesBeforeToken > 1) sequence.addBlank();
  }

  /// Writes comments before [token] when [token] is not the first element in
  /// a sequence.
  ///
  /// In that case, the comments are directly embedded in the [TextPiece]s for
  /// the preceding token and/or [token].
  void _writeNonSequenceComments(
      List<SourceComment> comments, int linesBeforeToken, Token token) {
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];
      var containsNewline =
          comment.type == CommentType.line || comment.text.contains('\n');

      if (_isHangingComment(comment)) {
        // Attach the comment to the previous token.
        writer.space();
        writer.write(comment.text,
            containsNewline: containsNewline, following: true);
      } else {
        writer.writeNewline();
        writer.write(comment.text, containsNewline: containsNewline);
      }

      if (comment.type == CommentType.line) writer.writeNewline();
    }

    if (comments.isNotEmpty && _needsSpaceAfterComment(token.lexeme)) {
      writer.space();
    }
  }

  /// Takes all of the comment tokens preceding [token] and converts them to
  /// [SourceComment]s that track their kind and the whitespace between them.
  ///
  /// Returns the list of [SourceComments] and the number of newlines between
  /// the last comment and [token]. If there are no comments, returns an empty
  /// list and the number of lines between [token] and the preceding token.
  (List<SourceComment>, int) _convertComments(Token token) {
    Token? comment = token.precedingComments;

    // TODO(perf): Avoid calculating newlines between tokens unless there are
    // comments or it's needed to determine whether to insert a blank in a
    // sequence.

    // TODO(tall): If the token's comments are being moved by a fix, do not
    // write them here.

    var previousLine = _endLine(token.previous!);
    var tokenLine = _startLine(token);

    // Edge case: The analyzer includes the "\n" in the script tag's lexeme,
    // which confuses some of these calculations. We don't want to allow a
    // blank line between the script tag and a following comment anyway, so
    // just override the script tag's line.
    if (token.previous!.type == TokenType.SCRIPT_TAG) previousLine = tokenLine;

    var comments = <SourceComment>[];
    while (comment != null) {
      var commentLine = _startLine(comment);

      // Don't preserve newlines at the top of the file.
      if (comment == token.precedingComments &&
          token.previous!.type == TokenType.EOF) {
        previousLine = commentLine;
      }

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

      var sourceComment =
          SourceComment(text, type, linesBefore, flushLeft: flushLeft);

      // TODO(tall): If this comment contains either of the selection endpoints,
      // mark them in the comment.

      comments.add(sourceComment);

      previousLine = _endLine(comment);
      comment = comment.next;
    }

    return (comments, tokenLine - previousLine);
  }

  /// Whether [comment] should be attached to the preceding token.
  bool _isHangingComment(SourceComment comment) {
    // Don't move a comment to a preceding line.
    if (comment.linesBefore != 0) return false;

    // Doc comments and non-inline `/* ... */` comments are always pushed to
    // the next line.
    if (comment.type == CommentType.doc) return false;
    if (comment.type == CommentType.block) return false;

    var text = writer.currentText;

    // Not if there is nothing before it.
    if (text == null) return false;

    // A block comment following a comma probably refers to the following item.
    if (text.endsWith(',') && comment.type == CommentType.inlineBlock) {
      return false;
    }

    // If the text before the split is an open grouping character, it looks
    // better to keep it with the elements than with the bracket itself.
    if (text.endsWith('(') ||
        text.endsWith('[') ||
        (text.endsWith('{') && !text.endsWith('\${'))) {
      return false;
    }

    return true;
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
