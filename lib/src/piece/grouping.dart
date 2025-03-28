// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a nested expression that should prevent its inner shape and
/// indentation from propagating outwards.
///
/// Used for index operands and string interpolation. Ensures we get:
///
///     variable =
///         '${a +
///             b}';
///
/// And not:
///
///     variable =
///         '${a +
///         b}';
final class GroupingPiece extends Piece {
  final Piece _content;

  GroupingPiece(this._content);

  @override
  void format(CodeWriter writer, State state) {
    writer.pushIndent(Indent.grouping);
    writer.setShapeMode(ShapeMode.other);
    writer.format(_content);
    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_content);
  }
}
