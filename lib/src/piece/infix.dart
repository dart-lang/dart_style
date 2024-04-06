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
  /// Split at the operators but require the first operand to fit one line.
  static const State _unsplitHeader = State(1);

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

  /// Whether the operation has [Shape.header] if the operators split and the
  /// first operand fits on one line.
  ///
  /// This is used for condition expressions to allow the condition on the
  /// same line as an assignment like:
  ///
  ///     variable = condition
  ///         ? thenBranch
  ///         : elseBranch;
  final bool _allowHeaderOperand;

  /// Whether operands after the first should be indented if split.
  final bool _indent;

  InfixPiece(this._leadingComments, this._operands,
      {bool allowHeaderOperand = false, bool indent = true})
      : _allowHeaderOperand = allowHeaderOperand,
        _indent = indent;

  @override
  List<State> get additionalStates =>
      [if (_allowHeaderOperand) _unsplitHeader, State.split];

  @override
  Shape shapeForState(State state) {
    if (state == _unsplitHeader) return Shape.header;
    return Shape.other;
  }

  @override
  void format(CodeWriter writer, State state) {
    if (state == _unsplitHeader && _indent) {
      writer.pushIndent(Indent.expression);
    }

    // Comments before the operands don't force the operator to split.
    for (var comment in _leadingComments) {
      writer.format(comment, allowNewlines: state != _unsplitHeader);
    }

    if (state != _unsplitHeader && _indent) {
      writer.pushIndent(Indent.expression);
    }

    for (var i = 0; i < _operands.length; i++) {
      // We can format each operand separately if the operand is on its own
      // line. This happens when the operator is split and we aren't the first
      // or last operand.
      var separate =
          state != State.unsplit && i > 0 && i < _operands.length - 1;

      writer.format(_operands[i],
          separate: separate,
          allowNewlines: switch (state) {
            State.split => true,
            _unsplitHeader => i != 0,
            _ => false,
          });

      if (i < _operands.length - 1) writer.splitIf(state != State.unsplit);
    }

    if (_indent) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
    _operands.forEach(callback);
  }

  @override
  List<State>? constrainByPageWidth(int pageWidth) {
    var totalLength = 0;

    var splitStates = _allowHeaderOperand
        ? const [_unsplitHeader, State.split]
        : const [State.split];

    for (var operand in _operands) {
      // If any operand contains a newline, then we have to split.
      if (operand.containsNewline) return splitStates;

      totalLength += operand.totalCharacters;
      if (totalLength > pageWidth) break;
    }

    // If the total length doesn't fit in the page, then we have to split.
    if (totalLength > pageWidth) return splitStates;

    return null;
  }
}
