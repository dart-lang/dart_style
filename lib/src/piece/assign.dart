// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

// TODO: Rewrite docs.
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
// TODO: Doc here.
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
/// [_splitLeftBlockSplitRight] Allow the right-hand side to block split or not,
/// if it wants. Since [State.unsplit] and [_blockSplitLeft] also allow the
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
  /// The left-hand side can split or not and the right-hand side must header
  /// split.
  static const State _headerRight = State(2, cost: 0);

  /// The left-hand side can expression split or not, and the right-hand side
  /// block splits.
  static const State _blockSplitRight = State(3, cost: 0);

  /// Both the left- and right-hand sides block split.
  static const State _blockSplitBoth = State(4);

  /// The left-hand side block splits and the right-hand side can expression
  /// split or not.
  static const State _blockSplitLeft = State(5);

  /// Split at the operator.
  static const State _atOperator = State(6);

  /// The left-hand side of the operation. Includes the operator unless it is
  /// `in`.
  final Piece? _left;

  final Piece _operator;

  /// The right-hand side of the operation.
  final Piece _right;

  final bool _splitBeforeOperator;

  AssignPiece(this._operator, this._right,
      {Piece? left, bool splitBeforeOperator = false})
      : _left = left,
        _splitBeforeOperator = splitBeforeOperator;

  // TODO(tall): The old formatter allows the first operand of a split
  // conditional expression to be on the same line as the `=`, as in:
  //
  //     var value = condition
  //         ? thenValue
  //         : elseValue;
  //
  // For now, we do not implement this special case behavior. Once more of the
  // language is implemented in the new back end and we can run the formatter
  // on a large corpus of code, we can try it out and see if the special case
  // behavior is worth it.

  @override
  List<State> get additionalStates => [
        if (_left != null) _blockSplitBoth,
        _blockSplitRight,
        if (_left != null) _blockSplitLeft,
        _headerRight,
        _atOperator
      ];

  @override
  void applyShapeConstraints(State state, ConstrainShape constrain) {
    switch (state) {
      case State.unsplit:
        // TODO: Can we do no-split constraints?
        break;

      case _headerRight:
        constrain(_right, Shape.header);
        break;

      case _blockSplitRight:
        // TODO: Could combine with previous state if we allow multiple shapes.
        constrain(_right, Shape.block);
        break;

      case _blockSplitBoth:
        constrain(_left!, Shape.block);
        constrain(_right, Shape.block);
        break;

      case _blockSplitLeft:
        constrain(_left!, Shape.block);

      case _atOperator:
        break; // No constraints.
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        _writeLeft(writer, allowNewlines: false);
        _writeOperator(writer, allowNewlines: false);
        _writeRight(writer, allowNewlines: false);

      case _headerRight:
        writer.pushIndent(Indent.expression);
        _writeLeft(writer);
        _writeOperator(writer);
        writer.popIndent();
        _writeRight(writer);

      case _blockSplitRight:
        _writeLeft(writer);
        _writeOperator(writer);
        _writeRight(writer);

      case _blockSplitBoth:
        _writeLeft(writer);
        _writeOperator(writer);
        _writeRight(writer);

      case _blockSplitLeft:
        _writeLeft(writer);
        writer.pushIndent(Indent.expression);
        _writeOperator(writer);
        _writeRight(writer);
        writer.popIndent();

      case _atOperator:
        writer.pushIndent(Indent.expression);
        _writeLeft(writer);
        _writeOperator(writer, split: true);
        _writeRight(writer);
        writer.popIndent();
    }
  }

  void _writeLeft(CodeWriter writer, {bool allowNewlines = true}) {
    if (_left case var left?) {
      writer.format(left, allowNewlines: allowNewlines);
    }
  }

  void _writeOperator(CodeWriter writer,
      {bool split = false, bool allowNewlines = true}) {
    if (_splitBeforeOperator) writer.splitIf(split);
    writer.format(_operator, allowNewlines: allowNewlines);
    if (!_splitBeforeOperator) writer.splitIf(split);
  }

  void _writeRight(CodeWriter writer, {bool allowNewlines = true}) {
    writer.format(_right, allowNewlines: allowNewlines);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_left case var left?) callback(left);
    callback(_operator);
    callback(_right);
  }
}
