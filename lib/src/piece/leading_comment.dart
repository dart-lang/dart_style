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
final class LeadingCommentPiece extends Piece {
  final List<Piece> _comments;
  final Piece _piece;

  LeadingCommentPiece(this._comments, this._piece);

  @override
  void format(CodeWriter writer, State state) {
    // If a piece has a leading comment, that comment should not also be a
    // hanging comment, so ensure it begins its own line. This is also important
    // to ensure that formatting is idempotent: If we don't do this, a comment
    // might be a leading comment in the input and then get output on the same
    // line as some preceding code, which would lead it to be a hanging comment
    // the next time the formatter runs.
    writer.newline();
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
