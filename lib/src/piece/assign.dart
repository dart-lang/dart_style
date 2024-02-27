// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for any construct where `=` is followed by an expression: variable
/// initializer, assignment, constructor initializer, etc.
///
/// This piece is also used for map entries and named arguments where `:` is
/// followed by an expression or element because those also want to support the
/// "block-like" formatting of delimited expressions on the right, and for the
/// `in` clause in for-in loops.
///
/// These constructs can be formatted four ways:
///
/// [State.unsplit] No split at all:
///
///     var x = 123;
///
/// This state also allows splitting the right side if it can be block
/// formatted:
///
///     var list = [
///       element,
///     ];
///
/// [_blockSplitLeft] Force the left-hand side, which must be a [ListPiece], to
/// split. Allow the right side to split or not. Allows all of:
///
///     var [
///       element,
///     ] = unsplitRhs;
///
///     var [
///       element,
///     ] = [
///       'block split RHS',
///     ];
///
///     var [
///       element,
///     ] = 'expression split' +
///         'the right hand side';
///
/// [_blockSplitRight] Allow the right-hand side to block split or not, if it
/// wants. Since [State.unsplit] and [_blockSplitLeft] also allow the
/// right-hand side to block split, this state is only used when the left-hand
/// side expression splits, like:
///
///     var (variable &&
///         anotherVariable) = [
///       element,
///     ];
///
/// [_atOperator] Split at the `=` or `in` operator and allow expression
/// splitting in either operand. Allows all of:
///
///     var (longVariable &&
///             anotherVariable) =
///         longOperand +
///             anotherOperand;
///
///     var [unsplitBlock] =
///         longOperand +
///             anotherOperand;
class AssignPiece extends Piece {
  /// Force the block left-hand side to split and allow the right-hand side to
  /// split.
  static const State _blockSplitLeft = State(1);

  /// Allow the right-hand side to block split.
  static const State _blockSplitRight = State(2);

  /// Split at the operator.
  static const State _atOperator = State(3);

  /// The left-hand side of the operation. Includes the operator unless it is
  /// `in`.
  final Piece? _left;

  final Piece _operator;

  /// The right-hand side of the operation.
  final Piece _right;

  final bool _splitBeforeOperator;

  /// If `true`, then the left side supports being block-formatted, like:
  ///
  ///     var [
  ///       element1,
  ///       element2,
  ///     ] = value;
  final bool _canBlockSplitLeft;

  /// If `true` then the right side supports being block-formatted, like:
  ///
  ///     var list = [
  ///       element1,
  ///       element2,
  ///     ];
  final bool _canBlockSplitRight;

  AssignPiece(this._operator, this._right,
      {Piece? left,
      bool splitBeforeOperator = false,
      bool canBlockSplitLeft = false,
      bool canBlockSplitRight = false})
      : _left = left,
        _splitBeforeOperator = splitBeforeOperator,
        _canBlockSplitLeft = canBlockSplitLeft,
        _canBlockSplitRight = canBlockSplitRight;

  // TODO(tall): The old formatter allows the first operand of a split
  // conditional expression to be on the same line as the `=`, as in:
  //
  //     var value = condition
  //         ? thenValue
  //         : elseValue;
  //
  // It's not clear if this behavior is deliberate or not. It does look OK,
  // though. We could do the same thing here. If we do, I think it's worth
  // considering allowing the same thing for infix expressions too:
  //
  //     var value = operand +
  //         operand +
  //         operand;
  //
  // For now, we do not implement this special case behavior. Once more of the
  // language is implemented in the new back end and we can run the formatter
  // on a large corpus of code, we can try it out and see if the special case
  // behavior is worth it.
  //
  // If we don't do that, consider at least not adding another level of
  // indentation for subsequent operands in an infix operator chain. So prefer:
  //
  //     var value =
  //         operand +
  //         operand +
  //         operand;
  //
  // Over:
  //
  //     var value =
  //         operand +
  //             operand +
  //             operand;

  @override
  List<State> get additionalStates => [
        // If at least one operand can block split, allow splitting in operands
        // without splitting at the operator.
        if (_canBlockSplitLeft) _blockSplitLeft,
        if (_canBlockSplitRight) _blockSplitRight,
        _atOperator,
      ];

  /// Apply constraints between how the parameters may split and how the
  /// initializers may split.
  @override
  void applyConstraints(State state, Constrain constrain) {
    switch (state) {
      case _blockSplitLeft:
        constrain(_left!, State.split);
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    var allowNewlinesInLeft = true;
    var indentLeft = false;
    var allowNewlinesInRight = true;
    var indentRight = false;
    var collapseIndent = false;

    switch (state) {
      case State.unsplit:
        allowNewlinesInLeft = false;

        // Always allow block-splitting the right side if it supports it.
        allowNewlinesInRight = _canBlockSplitRight;

      case _atOperator:
        // When splitting at the operator, both operands may split or not and
        // will be indented if they do.
        indentLeft = true;
        indentRight = true;

      case _blockSplitLeft:
        indentRight = !_canBlockSplitRight;
        collapseIndent = true;

      case _blockSplitRight:
        collapseIndent = true;
    }

    writer.pushAllowNewlines(allowNewlinesInLeft);
    if (indentLeft) {
      writer.pushIndent(Indent.expression, canCollapse: collapseIndent);
    }

    if (_left case var left?) writer.format(left);

    if (!_splitBeforeOperator) writer.format(_operator);
    writer.splitIf(state == _atOperator);
    if (_splitBeforeOperator) writer.format(_operator);

    if (indentLeft) writer.popIndent();
    writer.popAllowNewlines();

    writer.pushAllowNewlines(allowNewlinesInRight);
    if (indentRight) {
      writer.pushIndent(Indent.expression, canCollapse: collapseIndent);
    }

    writer.format(_right);

    if (indentRight) writer.popIndent();
    writer.popAllowNewlines();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_left case var left?) callback(left);
    callback(_operator);
    callback(_right);
  }
}
