// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../comment_type.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import 'comment_writer.dart';
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
  final List<ListElementPiece> _elements = [];

  /// The element that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElementPiece> _blanksAfter = {};

  /// The closing bracket after the elements, if any.
  Piece? _rightBracket;

  bool _mustSplit = false;

  final ListStyle _style;

  /// The comments that should appear before the next element.
  final List<Piece> _leadingComments = [];

  /// The list of comments following the most recently written element before
  /// any comma following the element.
  CommentSequence _commentsBeforeComma = CommentSequence.empty;

  /// Creates a new [DelimitedListBuilder] for an argument list, collection
  /// literal, etc.
  DelimitedListBuilder(this._visitor, [this._style = const ListStyle()]);

  /// Creates the final [ListPiece] out of the added brackets, delimiters,
  /// elements, and style.
  Piece build() {
    // To simplify the piece tree, if there are no elements, just return the
    // brackets concatenated together. We don't have to worry about comments
    // here since they would be in the [_elements] list if there were any.
    if (_elements.isEmpty) {
      return _visitor.pieces.build(() {
        if (_leftBracket case var bracket?) _visitor.pieces.add(bracket);
        if (_rightBracket case var bracket?) _visitor.pieces.add(bracket);
      });
    }

    if (_style.allowBlockElement) _setBlockElementFormatting();

    var piece =
        ListPiece(_leftBracket, _elements, _blanksAfter, _rightBracket, _style);
    if (_mustSplit) piece.pin(State.split);
    return piece;
  }

  /// Adds the opening [bracket] to the built list.
  void leftBracket(Token bracket) {
    addLeftBracket(_visitor.tokenPiece(bracket));
  }

  /// Adds the opening bracket [piece] to the built list.
  void addLeftBracket(Piece piece) {
    _leftBracket = piece;
  }

  /// Adds the closing [bracket] to the built list along with any comments that
  /// precede it.
  ///
  /// If [delimiter] is given, it is a second bracket occurring immediately
  /// after [bracket]. This is used for parameter lists with optional or named
  /// parameters, like:
  ///
  ///     function(mandatory, {named});
  ///
  /// Here, [bracket] will be `)` and [delimiter] will be `}`.
  ///
  /// If [semicolon] is given, it is the optional `;` in an enum declaration
  /// after the enum constants when there are no subsequent members. Comments
  /// before the `;` are kept, but the `;` itself is discarded.
  void rightBracket(Token bracket, {Token? delimiter, Token? semicolon}) {
    // Handle comments after the last element.
    var commentsBefore = _visitor.comments.takeCommentsBefore(bracket);

    // Merge the comments before the delimiter (if there is one) and the
    // bracket. If there is a delimiter, this will move comments between it and
    // the bracket to before the delimiter, as in:
    //
    //     // Before:
    //     f([parameter] /* comment */) {}
    //
    //     // After:
    //     f([parameter /* comment */]) {}
    if (delimiter != null) {
      commentsBefore = _visitor.comments
          .takeCommentsBefore(delimiter)
          .concatenate(commentsBefore);
    }

    if (semicolon != null) {
      commentsBefore = _visitor.comments
          .takeCommentsBefore(semicolon)
          .concatenate(commentsBefore);
    }

    _addComments(commentsBefore, hasElementAfter: false);

    _rightBracket = _visitor.pieces.build(() {
      _visitor.pieces.token(delimiter);
      _visitor.pieces.token(bracket);
    });
  }

  /// Adds [piece] to the built list.
  ///
  /// Use this when the piece is composed of more than one [AstNode] or [Token]
  /// and [visit()] can't be used. When calling this, make sure to call
  /// [addCommentsBefore()] for the first token in the [piece].
  ///
  /// Assumes there is no comma after this piece.
  void add(Piece piece, [BlockFormat format = BlockFormat.none]) {
    _elements.add(ListElementPiece(_leadingComments, piece, format));
    _leadingComments.clear();
    _commentsBeforeComma = CommentSequence.empty;
  }

  /// Writes any comments appearing before [token] to the list.
  void addCommentsBefore(Token token) {
    // Handle comments between the preceding element and this one.
    var commentsBeforeElement = _visitor.comments.takeCommentsBefore(token);
    _addComments(commentsBeforeElement, hasElementAfter: true);
  }

  /// Adds [element] to the built list.
  void visit(AstNode element) {
    // Handle comments between the preceding element and this one.
    addCommentsBefore(element.firstNonCommentToken);

    // See if it's an expression that supports block formatting.
    var format = switch (element) {
      AdjacentStrings(indentStrings: true) =>
        BlockFormat.indentedAdjacentStrings,
      AdjacentStrings() => BlockFormat.unindentedAdjacentStrings,
      Expression() => element.blockFormatType,
      DartPattern() when element.canBlockSplit => BlockFormat.collection,
      _ => BlockFormat.none,
    };

    // Traverse the element itself.
    add(_visitor.nodePiece(element), format);

    var nextToken = element.endToken.next!;
    if (nextToken.lexeme == ',') {
      _commentsBeforeComma = _visitor.comments.takeCommentsBefore(nextToken);
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
    //     function(p1, /* comment */ [p1]);
    //
    // Will be formatted as:
    //
    //     function(p1 /* comment */, [p1]);
    //
    // (In practice, it's such an unusual place for a comment that it doesn't
    // matter that much where it goes and this seems to be simple and
    // reasonable looking.)
    _commentsBeforeComma = _commentsBeforeComma
        .concatenate(_visitor.comments.takeCommentsBefore(delimiter));

    // Attach the delimiter to the previous element.
    _elements.last.setDelimiter(delimiter.lexeme);
  }

  /// Adds [comments] to the list.
  ///
  /// If [hasElementAfter] is `true` then another element will be written after
  /// these comments. Otherwise, we are at the comments after the last element
  /// before the closing delimiter.
  void _addComments(CommentSequence comments, {required bool hasElementAfter}) {
    // Early out if there's nothing to do.
    if (_commentsBeforeComma.isEmpty &&
        comments.isEmpty &&
        comments.linesBeforeNextToken <= 1) {
      return;
    }

    if (_commentsBeforeComma.requiresNewline || comments.requiresNewline) {
      _mustSplit = true;
    }

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
      var commentPiece = _visitor.pieces.commentPiece(comment);
      _elements.last.addComment(commentPiece, beforeDelimiter: true);
    }

    // Add any remaining hanging line comments to the previous element after
    // the ",".
    if (hangingComments.isNotEmpty) {
      for (var comment in hangingComments) {
        var commentPiece = _visitor.pieces.commentPiece(comment);
        _elements.last.addComment(commentPiece);
      }
    }

    // Preserve one blank line between successive elements.
    if (_elements.isNotEmpty && comments.linesBeforeNextToken > 1) {
      _blanksAfter.add(_elements.last);
    }

    // Comments that are neither hanging nor leading are treated like their own
    // elements.
    for (var i = 0; i < separateComments.length; i++) {
      var comment = separateComments[i];
      if (separateComments.linesBefore(i) > 1 && _elements.isNotEmpty) {
        _blanksAfter.add(_elements.last);
      }

      var commentPiece = _visitor.pieces.commentPiece(comment);
      _elements.add(ListElementPiece.comment(commentPiece));
    }

    // Leading comments are written before the next element.
    for (var comment in leadingComments) {
      var commentPiece = _visitor.pieces.commentPiece(comment);
      _leadingComments.add(commentPiece);
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
  ///     function(
  ///       argument /* inline */, // hanging
  ///       // separate
  ///       /* leading */ nextArgument
  ///     );
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
    //     function(
    //       argument /* hanging */ /* comment */,
    //       argument,
    //     );
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
    //     function(
    //       argument,
    //       /* leading */ /* comment */ argument,
    //     );
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
    //     function(
    //       argument,
    //       /* comment */
    //       argument,
    //       // another
    //     );
    var separateComments =
        separateCommentsBeforeComma.concatenate(separateCommentsAfterComma);

    return (
      inline: inlineComments,
      hanging: hangingComments,
      separate: separateComments,
      leading: leadingComments
    );
  }

  /// Looks at the [BlockFormat] types of all of the elements to determine if
  /// one of them should be block formatted.
  ///
  /// Also, if an argument list has an adjacent strings expression followed by a
  /// block formattable function expression, we allow the adjacent strings to
  /// split without forcing the list to split so that it can continue to have
  /// block formatting. This is pretty special-cased, but it makes calls to
  /// `test()` and `group()` look better and those are so common that it's
  /// worth massaging them some. It allows:
  ///
  ///     test('some long description'
  ///         'split across multiple lines', () {
  ///       expect(1, 1);
  ///     });
  ///
  /// Without this special rule, the newline in the adjacent strings would
  /// prevent block formatting and lead to the entire test body to be indented:
  ///
  ///     test(
  ///       'some long description'
  ///       'split across multiple lines',
  ///       () {
  ///         expect(1, 1);
  ///       },
  ///     );
  ///
  /// Stores the result of this calculation by setting flags on the
  /// [ListElement]s.
  void _setBlockElementFormatting() {
    // TODO(tall): These heuristics will probably need some iteration.
    var functions = <int>[];
    var collections = <int>[];
    var adjacentStrings = <int>[];

    for (var i = 0; i < _elements.length; i++) {
      switch (_elements[i].blockFormat) {
        case BlockFormat.function:
          functions.add(i);
        case BlockFormat.collection:
          collections.add(i);
        case BlockFormat.invocation:
          // We don't allow function calls as block elements partially for style
          // and partially for performance. It often doesn't look great to let
          // nested function calls pack arbitrarily deeply as block arguments:
          //
          //     ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          //         content: Text(
          //       localizations.demoSnackbarsAction,
          //     )));
          //
          // This is better when expanded like:
          //
          //     ScaffoldMessenger.of(context).showSnackBar(
          //       SnackBar(
          //         content: Text(
          //           localizations.demoSnackbarsAction,
          //         ),
          //       ),
          //     );
          //
          // Also, when invocations can be block arguments, which themselves
          // may contain block arguments, it's easy to run into combinatorial
          // performance in the solver as it tries to determine which of the
          // nested calls should and shouldn't be block formatted.
          break;
        case BlockFormat.indentedAdjacentStrings:
        case BlockFormat.unindentedAdjacentStrings:
          adjacentStrings.add(i);
        case BlockFormat.none:
          break; // Not a block element.
      }
    }

    switch ((functions, collections, adjacentStrings)) {
      // Only allow block formatting in an argument list containing adjacent
      // strings when:
      //
      // 1. The block argument is a function expression.
      // 2. It is the second argument, following an adjacent strings expression.
      // 3. There are no other adjacent strings in the argument list.
      //
      // This matches the `test()` and `group()` and other similar APIs where
      // you have a message string followed by a block-like function expression
      // but little else.
      // TODO(tall): We may want to iterate on these heuristics. For now,
      // starting with something very narrowly targeted.
      case ([1], _, [0]):
        // The adjacent strings.
        _elements[0].allowNewlinesWhenUnsplit = true;
        if (_elements[0].blockFormat == BlockFormat.unindentedAdjacentStrings) {
          _elements[0].indentWhenBlockFormatted = true;
        }

        // The block-formattable function.
        _elements[1].allowNewlinesWhenUnsplit = true;

      // A function expression takes precedence over other block arguments.
      case ([var element], _, _):
        _elements[element].allowNewlinesWhenUnsplit = true;

      // A single collection literal can be block formatted even if there are
      // other arguments.
      case ([], [var element], _):
        _elements[element].allowNewlinesWhenUnsplit = true;
    }

    // If we get here, there are no block element, or it's ambiguous as to
    // which one should be it so none are.
  }
}
