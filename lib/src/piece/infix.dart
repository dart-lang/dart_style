// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a series of binary expressions at the same precedence, like:
///
/// ```
/// a + b + c
/// ```
class InfixPiece extends Piece {
  /// The series of operands.
  ///
  /// Since we don't split on both sides of the operator, the operators will be
  /// embedded in the operand pieces. If the operator is a hanging one, it will
  /// be in the preceding operand, so `1 + 2` becomes "Infix(`1 +`, `2`)".
  /// A leading operator like `foo as int` becomes "Infix(`foo`, `as int`)".
  final List<Piece> operands;

  InfixPiece(this.operands);

  @override
  int get stateCount => 2;

  @override
  void format(CodeWriter writer, int state) {
    switch (state) {
      case 0:
        writer.setAllowNewlines(false);
        for (var i = 0; i < operands.length; i++) {
          writer.format(operands[i]);

          if (i < operands.length - 1) writer.space();
        }

      case 1:
        writer.setNesting(Indent.expression);
        for (var i = 0; i < operands.length; i++) {
          writer.format(operands[i]);
          if (i < operands.length - 1) writer.newline();
        }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    operands.forEach(callback);
  }

  @override
  String toString() => 'Infix';
}
