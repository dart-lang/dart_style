// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:collection';

import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../comment_type.dart';

/// Functionality used by [AstNodeVisitor], [DelimitedListBuilder], and
/// [SequenceBuilder] to build pieces from the comment tokens between meaningful
/// tokens used by AST nodes.
///
/// Also handles tracking newlines between tokens and comments so that
/// information can be used to preserve discretionary blank lines in places
/// where they are allowed. These are handled along with comments because both
/// comments and whitespace are found between the linear series of [Token]s
/// produced by the analyzer parser. Likewise, both are output as whitespace
/// (in the sense of not being executable code) interleaved with the
/// [Piece]-building code that walks the actual AST and processes the code
/// tokens.
///
/// Comments are a challenge because they confound the intuitive tree-like
/// structure of the code. A comment can appear between any two tokens, and a
/// line comment can force the formatter to insert a newline in places where
/// one wouldn't otherwise make sense. When that happens, the formatter then
/// has to decide how to indent the next line.
///
/// At the same time, comments appearing in idiomatic locations like between
/// statements should be formatted gracefully and give users control over the
/// blank lines around them. To support all of that, comments are handled in a
/// couple of different ways.
///
/// Comments between top-level declarations, member declarations inside types,
/// and statements are handled directly by [SequenceBuilder]. Comments inside
/// argument lists, collection literals, and other similar constructs are
/// handled directly be [DelimitedPieceBuilder].
///
/// All other comments occur inside the middle of some expression or other
/// construct. These get directly embedded in the [TextPiece] of the code being
/// written. When that [TextPiece] is output later, it will include the comments
/// as well.
final class CommentWriter {
  final LineInfo _lineInfo;

  /// The tokens whose preceding comments have already been taken by calls to
  /// [takeCommentsBefore()].
  final Set<Token> _takenTokens = {};

  CommentWriter(this._lineInfo);

  /// Returns the comments that appear before [token].
  ///
  /// The caller is required to write them because a later call to write [token]
  /// for this token will not write the preceding comments. Used by
  /// [SequenceBuilder] and [DelimitedListBuilder] which handle comment
  /// formatting themselves.
  CommentSequence takeCommentsBefore(Token token) {
    if (_takenTokens.contains(token)) return CommentSequence.empty;
    _takenTokens.add(token);
    return _commentsBefore(token);
  }

  /// Returns the comments that appear before [token].
  CommentSequence commentsBefore(Token token) {
    // In the common case where there are no comments before the token, early
    // out. This avoids calculating the number of newlines between every pair
    // of tokens which is slow and unnecessary.
    if (token.precedingComments == null) return CommentSequence.empty;

    // Don't yield the comments if some other construct already handled them.
    if (_takenTokens.contains(token)) return CommentSequence.empty;

    return _commentsBefore(token);
  }

  /// Takes all of the comment tokens preceding [token] and builds a
  /// [CommentSequence] that tracks them and the whitespace between them.
  CommentSequence _commentsBefore(Token token) {
    var previousLine = _endLine(token.previous!);
    var tokenLine = _startLine(token);

    // Edge case: The analyzer includes the "\n" in the script tag's lexeme,
    // which confuses some of these calculations. We don't want to allow a
    // blank line between the script tag and a following comment anyway, so
    // just override the script tag's line.
    if (token.previous!.type == TokenType.SCRIPT_TAG) previousLine = tokenLine;

    // ignore: prefer_const_constructors
    var comments = CommentSequence._([], []);
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

      var sourceComment = SourceComment(text, type,
          offset: comment.offset, flushLeft: flushLeft);

      comments._add(linesBefore, sourceComment);

      previousLine = _endLine(comment);
    }

    comments._setLinesBeforeNextToken(tokenLine - previousLine);
    return comments;
  }

  /// Whether there are any newlines between [from] and [to].
  bool hasNewlineBetween(Token from, Token to) =>
      _endLine(from) < _startLine(to);

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => _lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => _lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      _lineInfo.getLocation(token.offset).columnNumber;
}

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
final class SourceComment {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  final String text;

  final CommentType type;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool flushLeft;

  /// The number of code points in the original source code preceding the start
  /// of this comment.
  ///
  /// Used to track selection markers within the comment.
  final int offset;

  SourceComment(this.text, this.type,
      {required this.flushLeft, required this.offset});

  /// Whether this comment ends with a mandatory newline, because it's a line
  /// comment or a block comment that should be on its own line.
  bool get requiresNewline => type != CommentType.inlineBlock;

  @override
  String toString() =>
      '`$text` ${type.toString().replaceAll('CommentType.', '')}';
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
///     a /* c1 */
///     /* c2 */
///
///     /* c3 */
///
///
///     b
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
final class CommentSequence extends ListBase<SourceComment> {
  static const CommentSequence empty = CommentSequence._([0], []);

  /// The number of newlines between a pair of comments or the preceding or
  /// following tokens.
  ///
  /// This list is always one element longer than [_comments].
  final List<int> _linesBetween;

  final List<SourceComment> _comments;

  const CommentSequence._(this._linesBetween, this._comments);

  /// Whether this sequence contains any comments that require a newline.
  bool get requiresNewline =>
      _comments.any((comment) => comment.requiresNewline);

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
    // the next line. Only inline block comments and line comments are allowed
    // to hang at the end of a line.
    var type = _comments[commentIndex].type;
    return type == CommentType.inlineBlock || type == CommentType.line;
  }

  /// Whether the comment at [commentIndex] should be attached to the following
  /// token.
  bool isLeading(int commentIndex) {
    // Don't move code on the next line up to the comment.
    if (linesAfter(commentIndex) > 0) return false;

    // Doc comments and non-inline `/* ... */` comments are always pushed to
    // the next line.
    return _comments[commentIndex].type == CommentType.inlineBlock;
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
  void operator []=(int index, SourceComment value) =>
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

  /// Creates a new sequence that is this sequence followed by [other].
  ///
  /// Sums the trailing newline of the left sequence and the leading newline
  /// of the right sequence.
  CommentSequence concatenate(CommentSequence other) {
    // Don't allocate new sequences if we don't need to.
    if (isEmpty) return other;
    if (other.isEmpty) return this;

    var linesBetween = [
      // Include all of the newlines from the left sequence, except the last.
      for (var i = 0; i < _linesBetween.length - 1; i++) _linesBetween[i],
      // Combine the trailing newline of the left sequence and the leading
      // newline of the right sequence.
      _linesBetween[_linesBetween.length - 1] + other._linesBetween[0],
      // Include the remaining newlines of the right sequence.
      for (var i = 1; i < other._linesBetween.length; i++)
        other._linesBetween[i]
    ];

    var comments = [..._comments, ...other._comments];

    return CommentSequence._(linesBetween, comments);
  }

  /// Splits this sequence into two subsequences where [index] indicates the
  /// number of comments in the first returned sequence and the second
  /// sequence gets the rest.
  ///
  /// The newline count right at the split point goes to the first sequence and
  /// the second sequence gets an initial newline count of zero. For example,
  /// given this input sequence:
  ///
  /// * 4 newlines before `/* a */`
  /// * Comment `/* a */`
  /// * 5 newlines between `/* a */` and `/* b */`
  /// * Comment `/* b */`
  /// * 6 newlines between `/* b */` and `/* c */`
  /// * Comment `/* c */`
  /// * 7 newlines between `/* c */` and `/* d */`
  /// * Comment `/* d */`
  /// * 8 newlines between `/* d */` and `/* e */`
  /// * Comment `/* e */`
  /// * 9 newlines after `/* e */`
  ///
  /// Calling `splitAt(2)` yields:
  ///
  /// First sequence:
  ///
  /// * 4 newlines before `/* a */`
  /// * Comment `/* a */`
  /// * 5 newline between `/* a */` and `/* b */`
  /// * Comment `/* b */`
  /// * 6 newlines after `/* b */`
  ///
  /// Second sequence:
  ///
  /// * 0 newlines before `/* c */`
  /// * Comment `/* c */`
  /// * 7 newlines between `/* c */` and `/* d */`
  /// * Comment `/* d */`
  /// * 8 newlines between `/* d */` and `/* e */`
  /// * Comment `/* e */`
  /// * 9 newlines after `/* e */`
  (CommentSequence, CommentSequence) splitAt(int index) {
    // Don't allocate new sequences if we don't have to.
    if (index == 0) return (CommentSequence.empty, this);
    if (index == length) return (this, CommentSequence.empty);

    return (
      CommentSequence._(
          // +1 to include the newline after the last comment.
          _linesBetween.sublist(0, index + 1),
          _comments.sublist(0, index)),
      CommentSequence._(
          // 0 is the synthesized newline count before the first comment.
          [0, ..._linesBetween.sublist(index + 1, _linesBetween.length)],
          _comments.sublist(index, _comments.length))
    );
  }
}
