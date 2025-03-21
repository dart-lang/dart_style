// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a series of binary expressions at the same precedence, like:
///
///     a + b + c
final class InfixPiece extends Piece {
  /// The series of operands.
  ///
  /// Since we don't split on both sides of the operator, the operators will be
  /// embedded in the operand pieces. If the operator is a hanging one, it will
  /// be in the preceding operand, so `1 + 2` becomes "Infix(`1 +`, `2`)".
  /// A leading operator like `foo as int` becomes "Infix(`foo`, `as int`)".
  final List<Piece> _operands;

  /// What kind of indentation should be applied to the subsequent operands.
  final Indent _indentType;

  /// Whether this piece is for a conditional expression.
  final bool _isConditional;

  InfixPiece(
    this._operands, {
    bool conditional = false,
    Indent indent = Indent.infix,
  }) : _indentType = indent,
       _isConditional = conditional;

  @override
  List<State> get additionalStates => const [State.split];

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) =>
      Shape.anyIf(state == State.split);

  @override
  void format(CodeWriter writer, State state) {
    writer.pushIndent(_indentType);

    writer.format(_operands[0]);

    for (var i = 1; i < _operands.length; i++) {
      writer.splitIf(state == State.split);

      // If this is a branch of a conditional expression, then indent the
      // branch's contents past the `?` or `:`.
      if (_isConditional) writer.pushIndent(Indent.block);

      // We can format each operand separately if the operand is on its own
      // line. This happens when the operator is split and we aren't the first
      // or last operand.
      var separate = state == State.split && i < _operands.length - 1;
      writer.format(_operands[i], separate: separate);
      if (_isConditional) writer.popIndent();
    }

    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _operands.forEach(callback);
  }

  @override
  State? fixedStateForPageWidth(int pageWidth) {
    var totalLength = 0;

    for (var operand in _operands) {
      // If any operand contains a newline, then we have to split.
      if (operand.containsHardNewline) return State.split;

      totalLength += operand.totalCharacters;
      if (totalLength > pageWidth) break;
    }

    // If the total length doesn't fit in the page, then we have to split.
    if (totalLength > pageWidth) return State.split;

    return null;
  }
}
