// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a series of leading comments preceding some other piece.
///
/// We use this and hoist comments out from the inner piece so that a newline
/// in the comments doesn't erroneously force the inner piece to split. For
/// example, if comments preceding an infix operator's left operand:
///
///     value =
///         // comment
///         a + b;
///
/// Here, the `// comment` will be hoisted out and stored in a
/// [LeadingCommentPiece] instead of being a leading comment in the [CodePiece]
/// for `a`. If we left the comment in `a`, then the newline after the line
/// comment would force the `+` operator to split yielding:
///
///     value =
///         // comment
///         a +
///             b;
class LeadingCommentPiece extends Piece {
  final List<Piece> _comments;
  final Piece _piece;

  LeadingCommentPiece(this._comments, this._piece);

  @override
  void format(CodeWriter writer, State state) {
    for (var comment in _comments) {
      writer.format(comment);
    }

    writer.format(_piece);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _comments.forEach(callback);
    callback(_piece);
  }
}
