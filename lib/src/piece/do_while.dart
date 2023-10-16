// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a do-while statement.
class DoWhilePiece extends Piece {
  final Piece _body;
  final Piece _condition;

  DoWhilePiece(this._body, this._condition);

  @override
  List<State> get states => const [];

  @override
  void format(CodeWriter writer, State state) {
    writer.setIndent(Indent.none);
    writer.format(_body);
    writer.space();
    writer.format(_condition);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_body);
    callback(_condition);
  }

  @override
  String toString() => 'DoWhile';
}
