// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:dart_style/src/front_end/comment_writer.dart';

import '../comment_type.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import 'piece_factory.dart';

/// Incrementally builds a [ListPiece], handling commas, comments, and
/// newlines that may appear before, between, or after its contents.
///
/// Users of this should call [leftBracket()] first, passing in the opening
/// delimiter token. Then call [add()] for each [AstNode] that is inside the
/// delimiters. The [rightBracket()] with the closing delimiter and finally
/// [build()] to get the resulting [ListPiece].
class DelimitedListBuilder {
  final PieceFactory _visitor;

  late final Piece _leftBracket;

  /// The list of elements in the list.
  final List<ListElement> _elements = [];

  /// The element that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElement> _blanksAfter = {};

  late final Piece _rightBracket;

  bool _trailingComma = true;

  DelimitedListBuilder(this._visitor);

  /// The list of comments following the most recently written element before
  /// any comma following the element.
  CommentSequence _commentsBeforeComma = CommentSequence.empty;

  ListPiece build() => ListPiece(
      _leftBracket, _elements, _blanksAfter, _rightBracket, _trailingComma);

  /// Adds the opening [bracket] to the built list.
  void leftBracket(Token bracket) {
    _visitor.token(bracket);
    _leftBracket = _visitor.writer.pop();
    _visitor.writer.split();

    // No trailing commas in type argument and type parameter lists.
    if (bracket.type == TokenType.LT) _trailingComma = false;
  }

  /// Adds the closing [bracket] to the built list along with any comments that
  /// precede it.
  void rightBracket(Token bracket) {
    // Handle comments after the last element.
    _addComments(bracket, hasElementAfter: false);

    _visitor.token(bracket);
    _rightBracket = _visitor.writer.pop();
  }

  /// Adds [element] to the built list.
  ///
  /// Includes any comments that appear before element. Also includes the
  /// subsequent comma, if any, and any comments that precede the comma.
  void add(AstNode element) {
    // Handle comments between the preceding argument and this one.
    _addComments(element.beginToken, hasElementAfter: true);

    // Traverse the element itself.
    _visitor.visit(element);
    _elements.add(ListElement(_visitor.writer.pop()));
    _visitor.writer.split();

    var nextToken = element.endToken.next!;
    if (nextToken.lexeme != ',') {
      _commentsBeforeComma = CommentSequence.empty;
    } else {
      _commentsBeforeComma = _visitor.takeCommentsBefore(nextToken);
    }
  }

  /// Adds any comments preceding [token] the list.
  ///
  /// If [hasElementAfter] is `true` then another element will be written after
  /// these comments. Otherwise, we are at the comments after the last element
  /// before the closing delimiter.
  void _addComments(Token token, {required bool hasElementAfter}) {
    var commentsBeforeElement = _visitor.takeCommentsBefore(token);

    // Early out if there's nothing to do.
    if (_commentsBeforeComma.isEmpty && commentsBeforeElement.isEmpty) return;

    // Figure out which comments are anchored to the preceding element, which
    // are freestanding, and which are attached to the next element.
    var (
      hanging: hangingComments,
      separate: separateComments,
      leading: leadingComments
    ) = _splitCommaComments(commentsBeforeElement,
        hasElementAfter: hasElementAfter);

    // Add any hanging comments to the previous argument.
    if (hangingComments.isNotEmpty) {
      for (var comment in hangingComments) {
        _visitor.writer.space();
        _visitor.writer.writeComment(comment);
      }

      _elements.last = _elements.last.withComment(_visitor.writer.pop());
      _visitor.writer.split();
    }

    // Comments that are neither hanging nor leading are treated like their own
    // arguments.
    for (var i = 0; i < separateComments.length; i++) {
      var comment = separateComments[i];
      if (separateComments.linesBefore(i) > 1 && _elements.isNotEmpty) {
        _blanksAfter.add(_elements.last);
      }

      _visitor.writer.writeComment(comment);
      _elements.add(ListElement.comment(_visitor.writer.pop()));
      _visitor.writer.split();
    }

    // Leading comments are written before the next argument.
    for (var comment in leadingComments) {
      _visitor.writer.writeComment(comment);
      _visitor.writer.space();
    }
  }

  /// Given the comments that followed the previous element before its comma
  /// and [commentsBeforeElement], the comments before the element we are about
  /// to write (and after the preceding element's comma), splits them into to
  /// three comment sequences:
  ///
  /// * The comments that should hang off the end of the preceding element.
  /// * The comments that should be formatted like separate elements.
  /// * The comments that should lead the beginning of the next element we are
  ///   about to write.
  ///
  /// For example:
  ///
  /// ```
  /// function(
  ///   argument /* hanging */,
  ///   // separate
  ///   /* leading */
  /// );
  /// ```
  ///
  /// Calculating these takes into account whether there are newlines before or
  /// after the comments, and which side of the commas the comments appear on.
  ///
  /// If [hasElementAfter] is `true` then another element will be written after
  /// these comments. Otherwise, we are at the comments after the last element
  /// before the closing delimiter.
  ({CommentSequence hanging, CommentSequence separate, CommentSequence leading})
      _splitCommaComments(CommentSequence commentsBeforeElement,
          {required bool hasElementAfter}) {
    // If we're on the final comma after the last argument, the comma isn't
    // meaningful because there can't be leading comments after it.
    if (!hasElementAfter) {
      _commentsBeforeComma =
          _commentsBeforeComma.concatenate(commentsBeforeElement);
      commentsBeforeElement = CommentSequence.empty;
    }

    // Edge case: A line comment on the same line as the preceding argument
    // but after the comma is treated as hanging.
    if (commentsBeforeElement.isNotEmpty &&
        commentsBeforeElement[0].type == CommentType.line &&
        commentsBeforeElement.linesBefore(0) == 0) {
      var (hanging, remaining) = commentsBeforeElement.splitAt(1);
      _commentsBeforeComma = _commentsBeforeComma.concatenate(hanging);
      commentsBeforeElement = remaining;
    }

    // Inline block comments on the same line as a preceding element hang
    // on that same line, as in:
    //
    // ```
    // function(
    //   argument /* hanging */ /* comment */,
    //   argument,
    // );
    // ```
    var hangingCommentCount = 0;
    if (_elements.isNotEmpty) {
      while (hangingCommentCount < _commentsBeforeComma.length) {
        // Once we hit a single non-hanging comment, the rest won't be either.
        if (!_commentsBeforeComma.isHanging(hangingCommentCount)) break;

        hangingCommentCount++;
      }
    }

    var (hangingComments, separateCommentsBeforeComma) =
        _commentsBeforeComma.splitAt(hangingCommentCount);

    // Inline block comments on the same line as the next element lead at the
    // beginning of that line, as in:
    ///
    // ```
    // function(
    //   argument,
    //   /* leading */ /* comment */ argument,
    // );
    // ```
    var leadingCommentCount = 0;
    if (hasElementAfter && commentsBeforeElement.isNotEmpty) {
      while (leadingCommentCount < commentsBeforeElement.length) {
        // Count backwards from the end. Once we hit a non-leading comment, the
        // preceding ones aren't either.
        var commentIndex =
            commentsBeforeElement.length - leadingCommentCount - 1;
        if (!commentsBeforeElement.isLeading(commentIndex)) break;

        leadingCommentCount++;
      }
    }

    var (separateCommentsAfterComma, leadingComments) = commentsBeforeElement
        .splitAt(commentsBeforeElement.length - leadingCommentCount);

    // Comments that are neither hanging nor leading are formatted like
    // separate elements, as in:
    //
    // ```
    // function(
    //   argument,
    //   /* comment */
    //   argument,
    //   // another
    // );
    // ```
    var separateComments =
        separateCommentsBeforeComma.concatenate(separateCommentsAfterComma);

    return (
      hanging: hangingComments,
      separate: separateComments,
      leading: leadingComments
    );
  }
}
