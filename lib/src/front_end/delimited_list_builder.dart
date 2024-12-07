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
final class DelimitedListBuilder {
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
  Piece build({bool forceSplit = false}) {
    // To simplify the piece tree, if there are no elements, just return the
    // brackets concatenated together. We don't have to worry about comments
    // here since they would be in the [_elements] list if there were any.
    if (_elements.isEmpty) {
      return _visitor.pieces.build(() {
        if (_leftBracket case var bracket?) _visitor.pieces.add(bracket);
        if (_rightBracket case var bracket?) _visitor.pieces.add(bracket);
      });
    }

    var piece =
        ListPiece(_leftBracket, _elements, _blanksAfter, _rightBracket, _style);
    if (_mustSplit || forceSplit) piece.pin(State.split);
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
  void add(Piece piece) {
    _elements.add(ListElementPiece(_leadingComments, piece));
    _leadingComments.clear();
    _commentsBeforeComma = CommentSequence.empty;
  }

  /// Adds all of [pieces] to the built list.
  void addAll(Iterable<Piece> pieces) {
    pieces.forEach(add);
  }

  /// Adds the contents of [inner] to this outer [DelimitedListBuilder].
  ///
  /// This is used when a [DelimiterListBuilder] is building a piece that will
  /// then become an element in a surrounding [DelimitedListBuilder]. It ensures
  /// that any comments around a trailing comma after [inner] don't get lost and
  /// are instead hoisted up to be captured by this builder.
  void addInnerBuilder(DelimitedListBuilder inner) {
    // Add the elements of the line to this builder.
    add(inner.build());

    // Make sure that any trailing comments on the line aren't lost.
    _commentsBeforeComma = inner._commentsBeforeComma;
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

    // Traverse the element itself.
    add(_visitor.nodePiece(element));

    var nextToken = element.endToken.next!;
    if (nextToken.lexeme == ',') {
      _commentsBeforeComma = _visitor.comments.takeCommentsBefore(nextToken);
    }
  }

  /// Visits a list of [elements].
  ///
  /// If [allowBlockArgument] is `true`, then allows one element to receive
  /// block formatting if appropriate, as in:
  ///
  ///     function(argument, [
  ///       block,
  ///       like,
  ///     ], argument);
  void visitAll(List<AstNode> elements, {bool allowBlockArgument = false}) {
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      visit(element);
    }

    if (allowBlockArgument) _setBlockArgument(elements);
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

  /// Given an argument list, determines which if any of the arguments should
  /// get special block-like formatting as in the list literal in:
  ///
  ///     function(argument, [
  ///       block,
  ///       like,
  ///     ], argument);
  ///
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
  void _setBlockArgument(List<AstNode> arguments) {
    var candidateIndex = _candidateBlockArgument(arguments);
    if (candidateIndex == -1) return;

    // The block argument must be positional.
    if (arguments[candidateIndex] is NamedExpression) return;

    // Only allow up to one trailing argument after the block argument. This
    // handles the common `tags` and `timeout` named arguments in `test()` and
    // `group()` while still mostly having the block argument be at the end of
    // the argument list.
    if (candidateIndex < arguments.length - 2) return;

    // Edge case: If the first argument is adjacent strings and the second
    // argument is a function literal, with optionally a third non-block
    // argument, then treat the function as the block argument.
    //
    // This matches the `test()` and `group()` and other similar APIs where
    // you have a message string followed by a block-like function expression
    // but little else, as in:
    //
    //     test('Some long test description '
    //         'that splits into multiple lines.', () {
    //       expect(1 + 2, 3);
    //     });
    if (candidateIndex == 1 &&
        arguments[1].blockFormatType == BlockFormat.function &&
        arguments[0] is! NamedExpression) {
      var firstArgumentFormatType = arguments[0].blockFormatType;
      if (firstArgumentFormatType
          case BlockFormat.unindentedAdjacentStrings ||
              BlockFormat.indentedAdjacentStrings) {
        // The adjacent strings.
        _elements[0].allowNewlinesWhenUnsplit = true;
        if (firstArgumentFormatType == BlockFormat.unindentedAdjacentStrings) {
          _elements[0].indentWhenBlockFormatted = true;
        }

        // The block-formattable function.
        _elements[1].allowNewlinesWhenUnsplit = true;
        return;
      }
    }

    // If we get here, we have a block argument.
    _elements[candidateIndex].allowNewlinesWhenUnsplit = true;
  }

  /// If an argument in [arguments] is a candidate to be block formatted,
  /// returns its index.
  ///
  /// If there is a single non-empty block bodied function expression in
  /// [arguments], returns its index. Otherwise, if there is a single non-empty
  /// collection literal in [arguments], returns its index. Otherwise, returns
  /// `-1`.
  int _candidateBlockArgument(List<AstNode> arguments) {
    // The index of the function expression argument, or -1 if none has been
    // found or -2 if there are multiple.
    var functionIndex = -1;

    // The index of the collection literal argument, or -1 if none has been
    // found or -2 if there are multiple.
    var collectionIndex = -1;

    for (var i = 0; i < arguments.length; i++) {
      // See if it's an expression that supports block formatting.
      switch (arguments[i].blockFormatType) {
        case BlockFormat.function:
          if (functionIndex >= 0) {
            functionIndex = -2;
          } else {
            functionIndex = i;
          }

        case BlockFormat.collection:
          if (collectionIndex >= 0) {
            collectionIndex = -2;
          } else {
            collectionIndex = i;
          }

        case BlockFormat.invocation:
        case BlockFormat.indentedAdjacentStrings:
        case BlockFormat.unindentedAdjacentStrings:
        case BlockFormat.none:
          break; // Normal argument.
      }
    }

    if (functionIndex >= 0) return functionIndex;
    if (collectionIndex >= 0) return collectionIndex;

    return -1;
  }
}
