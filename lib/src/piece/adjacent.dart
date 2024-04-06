// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A simple piece that just writes its child pieces one after the other.
class AdjacentPiece extends Piece {
  final List<Piece> pieces;

  /// The index of the child piece that any shape constraints applied to this
  /// piece should be forwarded to, or -1 if no constraint should be forwarded.
  final int _forwardShapeConstraintIndex;

  AdjacentPiece(this.pieces, [this._forwardShapeConstraintIndex = -1]);

  @override
  Piece forwardShapeConstraint() {
    if (_forwardShapeConstraintIndex != -1) {
      return pieces[_forwardShapeConstraintIndex];
    }

    // Don't forward.
    return this;
  }

  @override
  void format(CodeWriter writer, State state) {
    for (var piece in pieces) {
      writer.format(piece);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    pieces.forEach(callback);
  }
}
