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

  /// The opening bracket before the elements, if any.
  Piece? _leftBracket;

  /// The list of elements in the list.
  final List<ListElement> _elements = [];

  /// The element that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElement> _blanksAfter = {};

  /// The closing bracket after the elements, if any.
  Piece? _rightBracket;

  final ListStyle _style;

  /// The list of comments following the most recently written element before
  /// any comma following the element.
  CommentSequence _commentsBeforeComma = CommentSequence.empty;

  /// Creates a new [DelimitedListBuilder] for an argument list, collection
  /// literal, etc.
  DelimitedListBuilder(this._visitor, [this._style = const ListStyle()]);

  ListPiece build() =>
      ListPiece(_leftBracket, _elements, _blanksAfter, _rightBracket, _style);

  /// Adds the opening [bracket] to the built list.
  ///
  /// If [delimiter] is given, it is a second bracket occurring immediately
  /// after [bracket]. This is used for parameter lists where all parameters
  /// are optional or named, as in:
  ///
  /// ```
  /// function([parameter]);
  /// ```
  ///
  /// Here, [bracket] will be `(` and [delimiter] will be `[`.
  void leftBracket(Token bracket, {Token? delimiter}) {
    _visitor.token(bracket);
    _visitor.token(delimiter);
    _leftBracket = _visitor.pieces.split();
  }

  /// Adds the closing [bracket] to the built list along with any comments that
  /// precede it.
  ///
  /// If [delimiter] is given, it is a second bracket occurring immediately
  /// after [bracket]. This is used for parameter lists with optional or named
  /// parameters, like:
  ///
  /// ```
  /// function(mandatory, {named});
  /// ```
  ///
  /// Here, [bracket] will be `)` and [delimiter] will be `}`.
  void rightBracket(Token bracket, {Token? delimiter}) {
    // Handle comments after the last element.

    // Merge the comments before the delimiter (if there is one) and the
    // bracket. If there is a delimiter, this will move comments between it and
    // the bracket to before the delimiter, as in:
    //
    // ```
    // // Before:
    // f([parameter] /* comment */) {}
    //
    // // After:
    // f([parameter /* comment */]) {}
    // ```
    var commentsBefore = _visitor.takeCommentsBefore(bracket);
    if (delimiter != null) {
      commentsBefore =
          _visitor.takeCommentsBefore(delimiter).concatenate(commentsBefore);
    }
    _addComments(commentsBefore, hasElementAfter: false);

    _visitor.token(delimiter);
    _visitor.token(bracket);
    _rightBracket = _visitor.pieces.pop();
  }

  /// Adds [piece] to the built list.
  ///
  /// Use this when the piece is composed of more than one [AstNode] or [Token]
  /// and [visit()] can't be used. When calling this, make sure to call
  /// [addCommentsBefore()] for the first token in the [piece].
  ///
  /// Assumes there is no comma after this piece.
  void add(Piece piece) {
    _elements.add(ListElement(piece));
    _commentsBeforeComma = CommentSequence.empty;
  }

  /// Writes any comments appearing before [token] to the list.
  void addCommentsBefore(Token token) {
    // Handle comments between the preceding element and this one.
    var commentsBeforeElement = _visitor.takeCommentsBefore(token);
    _addComments(commentsBeforeElement, hasElementAfter: true);
  }

  /// Adds [element] to the built list.
  void visit(AstNode element) {
    // Handle comments between the preceding element and this one.
    addCommentsBefore(element.beginToken);

    // Traverse the element itself.
    _visitor.visit(element);
    add(_visitor.pieces.split());

    var nextToken = element.endToken.next!;
    if (nextToken.lexeme == ',') {
      _commentsBeforeComma = _visitor.takeCommentsBefore(nextToken);
    }
  }

  /// Inserts an inner left delimiter between two elements.
  ///
  /// This is used for parameter lists when there are both mandatory and
  /// optional or named parameters to insert the `[` or `{`, respectively.
  ///
  /// This should not be used if [delimiter] appears before all elements. In
  /// that case, pass it to [leftBracket].
  void leftDelimiter(Token delimiter) {
    assert(_elements.isNotEmpty);

    // Preserve any comments before the delimiter. Treat them as occurring
    // before the previous element's comma. This means that:
    //
    // ```
    // function(p1, /* comment */ [p1]);
    // ```
    //
    // Will be formatted as:
    //
    // ```
    // function(p1 /* comment */, [p1]);
    // ```
    //
    // (In practice, it's such an unusual place for a comment that it doesn't
    // matter that much where it goes and this seems to be simple and
    // reasonable looking.)
    _commentsBeforeComma = _commentsBeforeComma
        .concatenate(_visitor.takeCommentsBefore(delimiter));

    // Attach the delimiter to the previous element.
    _elements.last = _elements.last.withDelimiter(delimiter.lexeme);
  }

  /// Adds [comments] to the list.
  ///
  /// If [hasElementAfter] is `true` then another element will be written after
  /// these comments. Otherwise, we are at the comments after the last element
  /// before the closing delimiter.
  void _addComments(CommentSequence comments, {required bool hasElementAfter}) {
    // Early out if there's nothing to do.
    if (_commentsBeforeComma.isEmpty && comments.isEmpty) return;

    // Figure out which comments are anchored to the preceding element, which
    // are freestanding, and which are attached to the next element.
    var (
      inline: inlineComments,
      hanging: hangingComments,
      separate: separateComments,
      leading: leadingComments
    ) = _splitCommaComments(comments, hasElementAfter: hasElementAfter);

    // Add any hanging inline block comments to the previous element before the
    // subsequent ",".
    for (var comment in inlineComments) {
      _visitor.space();
      _visitor.pieces.writeComment(comment, hanging: true);
    }

    // Add any remaining hanging line comments to the previous element after
    // the ",".
    if (hangingComments.isNotEmpty) {
      for (var comment in hangingComments) {
        _visitor.space();
        _visitor.pieces.writeComment(comment);
      }

      _elements.last = _elements.last.withComment(_visitor.pieces.split());
    }

    // Comments that are neither hanging nor leading are treated like their own
    // elements.
    for (var i = 0; i < separateComments.length; i++) {
      var comment = separateComments[i];
      if (separateComments.linesBefore(i) > 1 && _elements.isNotEmpty) {
        _blanksAfter.add(_elements.last);
      }

      _visitor.pieces.writeComment(comment);
      _elements.add(ListElement.comment(_visitor.pieces.split()));
    }

    // Leading comments are written before the next element.
    for (var comment in leadingComments) {
      _visitor.pieces.writeComment(comment);
      _visitor.space();
    }
  }

  /// Given the comments that followed the previous element before its comma
  /// and [commentsBeforeElement], the comments before the element we are about
  /// to write (and after the preceding element's comma), splits them into to
  /// four comment sequences:
  ///
  /// * The inline block comments that should hang off the preceding element
  ///   before its comma.
  /// * The line comments that should hang off the end of the preceding element
  ///   after its comma.
  /// * The comments that should be formatted like separate elements.
  /// * The comments that should lead the beginning of the next element we are
  ///   about to write.
  ///
  /// For example:
  ///
  /// ```
  /// function(
  ///   argument /* inline */, // hanging
  ///   // separate
  ///   /* leading */ nextArgument
  /// );
  /// ```
  ///
  /// Calculating these takes into account whether there are newlines before or
  /// after the comments, and which side of the commas the comments appear on.
  ///
  /// If [hasElementAfter] is `true` then another element will be written after
  /// these comments. Otherwise, we are at the comments after the last element
  /// before the closing delimiter.
  ({
    CommentSequence inline,
    CommentSequence hanging,
    CommentSequence separate,
    CommentSequence leading
  }) _splitCommaComments(CommentSequence commentsBeforeElement,
      {required bool hasElementAfter}) {
    // If we're on the final comma after the last element, the comma isn't
    // meaningful because there can't be leading comments after it.
    if (!hasElementAfter) {
      _commentsBeforeComma =
          _commentsBeforeComma.concatenate(commentsBeforeElement);
      commentsBeforeElement = CommentSequence.empty;
    }

    // Edge case: A line comment on the same line as the preceding element
    // but after the comma is treated as hanging.
    if (commentsBeforeElement.isNotEmpty &&
        commentsBeforeElement[0].type == CommentType.line &&
        commentsBeforeElement.linesBefore(0) == 0) {
      var (hanging, remaining) = commentsBeforeElement.splitAt(1);
      _commentsBeforeComma = _commentsBeforeComma.concatenate(hanging);
      commentsBeforeElement = remaining;
    }

    // Inline block comments before the `,` stay with the preceding element, as
    // in:
    //
    // ```
    // function(
    //   argument /* hanging */ /* comment */,
    //   argument,
    // );
    // ```
    var inlineCommentCount = 0;
    if (_elements.isNotEmpty) {
      while (inlineCommentCount < _commentsBeforeComma.length) {
        // Once we hit a single non-inline comment, the rest won't be either.
        if (!_commentsBeforeComma.isHanging(inlineCommentCount) ||
            _commentsBeforeComma[inlineCommentCount].type !=
                CommentType.inlineBlock) {
          break;
        }

        inlineCommentCount++;
      }
    }

    var (inlineComments, remainingCommentsBeforeComma) =
        _commentsBeforeComma.splitAt(inlineCommentCount);

    var hangingCommentCount = 0;
    if (_elements.isNotEmpty) {
      while (hangingCommentCount < remainingCommentsBeforeComma.length) {
        // Once we hit a single non-hanging comment, the rest won't be either.
        if (!remainingCommentsBeforeComma.isHanging(hangingCommentCount)) break;

        hangingCommentCount++;
      }
    }

    var (hangingComments, separateCommentsBeforeComma) =
        remainingCommentsBeforeComma.splitAt(hangingCommentCount);

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
      inline: inlineComments,
      hanging: hangingComments,
      separate: separateComments,
      leading: leadingComments
    );
  }
}
