// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a series of binary expressions at the same precedence, like:
///
///     a + b + c
class InfixPiece extends Piece {
  /// Pieces for leading comments that appear before the first operand.
  ///
  /// We hoist these comments out from the first operand's first token so that
  /// a newline in these comments doesn't erroneously force the infix operator
  /// to split. For example:
  ///
  ///     value =
  ///         // comment
  ///         a + b;
  ///
  /// Here, the `// comment` will be hoisted out and stored in
  /// [_leadingComments] instead of being a leading comment in the [CodePiece]
  /// for `a`. If we left the comment in `a`, then the newline after the line
  /// comment would force the `+` operator to split yielding:
  ///
  ///     value =
  ///         // comment
  ///         a +
  ///             b;
  final List<Piece> _leadingComments;

  /// The series of operands.
  ///
  /// Since we don't split on both sides of the operator, the operators will be
  /// embedded in the operand pieces. If the operator is a hanging one, it will
  /// be in the preceding operand, so `1 + 2` becomes "Infix(`1 +`, `2`)".
  /// A leading operator like `foo as int` becomes "Infix(`foo`, `as int`)".
  final List<Piece> _operands;

  /// Whether operands after the first should be indented if split.
  final bool _indent;

  InfixPiece(this._leadingComments, this._operands, {bool indent = true})
      : _indent = indent;

  @override
  List<State> get additionalStates => const [State.split];

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (state == State.split) return true;

    // Comments before the operands don't force the operator to split.
    return _leadingComments.contains(child);
  }

  @override
  void format(CodeWriter writer, State state) {
    for (var comment in _leadingComments) {
      writer.format(comment);
    }

    if (_indent) writer.pushIndent(Indent.expression);

    for (var i = 0; i < _operands.length; i++) {
      // We can format each operand separately if the operand is on its own
      // line. This happens when the operator is split and we aren't the first
      // or last operand.
      var separate = state == State.split && i > 0 && i < _operands.length - 1;

      writer.format(_operands[i], separate: separate);
      if (i < _operands.length - 1) writer.splitIf(state == State.split);
    }

    if (_indent) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
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
