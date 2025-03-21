// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for parenthesized expressions and patterns.
///
/// Also used for other contexts where we want to prevent surrounding
/// indentation from being merged with the indentation of an inner construct.
final class GroupingPiece extends Piece {
  final Piece _content;

  GroupingPiece(this._content);

  @override
  void format(CodeWriter writer, State state) {
    // Prevent the inner construct's indentation from being merged with the
    // surrounding context. Ensures we get:
    //
    //     // Merging OK here:
    //     variable =
    //         operand +
    //         another;
    //
    //     // Merging not OK here:
    //     variable =
    //         !(operand +
    //             another);
    writer.pushIndent(Indent.grouping);
    writer.format(_content);
    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_content);
  }
}
