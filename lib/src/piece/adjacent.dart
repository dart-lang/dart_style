// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A simple piece that just writes its child pieces one after the other.
class AdjacentPiece extends Piece {
  final List<Piece> _pieces;

  /// The pieces that should have a space after them.
  final Set<Piece> _spaceAfter;

  AdjacentPiece(this._pieces, {List<Piece> spaceAfter = const []})
      : _spaceAfter = spaceAfter.toSet();

  @override
  void format(CodeWriter writer, State state) {
    for (var piece in _pieces) {
      writer.format(piece);
      if (_spaceAfter.contains(piece)) writer.space();
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _pieces.forEach(callback);
  }
}
