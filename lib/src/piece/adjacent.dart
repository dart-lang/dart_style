// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A simple piece that just writes its child pieces one after the other.
final class AdjacentPiece extends Piece {
  final List<Piece> pieces;

  AdjacentPiece(this.pieces);

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
