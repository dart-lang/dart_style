// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for an assignment-like construct where an operator is followed by
/// an expression but where the left side of the operator isn't also an
/// expression. Used for:
///
/// - Assignment (`=`, `+=`, etc.)
/// - Named arguments (`:`)
/// - Map entries (`:`)
/// - Record fields (`:`)
/// - Expression function bodies (`=>`)
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

  /// The left-hand side of the operation.
  final Piece? _left;

  // TODO(rnystrom): If it wasn't for the need to constrain [_left] to split
  // in [applyConstraints()], we could write the operator into the same piece
  // as [_left]. In the common case where the AssignPiece is for a named
  // argument, the name and `:` would then end up in a single atomic
  // [CodePiece].

  /// The `=` or other operator.
  final Piece _operator;

  /// The right-hand side of the operation.
  final Piece _right;

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
      bool canBlockSplitLeft = false,
      bool canBlockSplitRight = false})
      : _left = left,
        _canBlockSplitLeft = canBlockSplitLeft,
        _canBlockSplitRight = canBlockSplitRight;

  @override
  List<State> get additionalStates => [
        // If at least one operand can block split, allow splitting in operands
        // without splitting at the operator.
        if (_canBlockSplitLeft) _blockSplitLeft,
        if (_canBlockSplitRight) _blockSplitRight,
        _atOperator,
      ];

  @override
  void applyConstraints(State state, Constrain constrain) {
    // Force the left side to block split when in that state.
    //
    // Otherwise, the solver may instead leave it unsplit and then split the
    // right side incorrectly as in:
    //
    //  (x, y) = longOperand2 +
    //      longOperand2 +
    //      longOperand3;
    if (state == _blockSplitLeft) constrain(_left!, State.split);
  }

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (state == State.unsplit) {
      if (child == _left) return false;

      // Always allow block-splitting the right side if it supports it.
      if (child == _right) return _canBlockSplitRight;
    }

    return true;
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        _writeLeft(writer, allowNewlines: false);
        _writeOperator(writer);
        // Always allow block-splitting the right side if it supports it.
        _writeRight(writer, allowNewlines: _canBlockSplitRight);

      case _atOperator:
        // When splitting at the operator, both operands may split or not and
        // will be indented if they do.
        writer.pushIndent(Indent.expression);
        _writeLeft(writer);
        _writeOperator(writer, split: state == _atOperator);
        _writeRight(writer);
        writer.popIndent();

      case _blockSplitLeft:
        _writeLeft(writer);
        _writeOperator(writer);
        _writeRight(writer, indent: !_canBlockSplitRight);

      case _blockSplitRight:
        _writeLeft(writer);
        _writeOperator(writer, split: state == _atOperator);
        _writeRight(writer);
    }
  }

  void _writeLeft(CodeWriter writer, {bool allowNewlines = true}) {
    if (_left case var left?) writer.format(left);
  }

  void _writeOperator(CodeWriter writer, {bool split = false}) {
    writer.pushIndent(Indent.expression);
    writer.format(_operator);
    writer.popIndent();
    writer.splitIf(split);
  }

  void _writeRight(CodeWriter writer,
      {bool indent = false, bool allowNewlines = true}) {
    if (indent) writer.pushIndent(Indent.expression);
    writer.format(_right);
    if (indent) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_left case var left?) callback(left);
    callback(_operator);
    callback(_right);
  }

  @override
  State? fixedStateForPageWidth(int pageWidth) {
    // If either side (or both) can block split, then they may allow a long
    // assignment to still not end up splitting at the operator.
    if (_canBlockSplitLeft || _canBlockSplitRight) return null;

    // Edge case: If the left operand is only a single character, then splitting
    // at the operator won't actually make the line any smaller, so don't apply
    // the optimization in that case:
    //
    //     e = someVeryLongExpression;
    //
    // Is no worse than:
    //
    //     e =
    //         someVeryLongExpression;
    if (_left case var left? when left.totalCharacters == 1) return null;

    // If either operand contains a newline or the whole assignment doesn't
    // fit then it will split at the operator since there's no other way it
    // can split because there are no block operands.
    var totalLength = 0;
    if (_left case var left? when !_canBlockSplitLeft) {
      if (left.containsHardNewline) return _atOperator;

      totalLength += left.totalCharacters;
    }

    totalLength += _operator.totalCharacters;

    if (!_canBlockSplitRight) {
      if (_right.containsHardNewline) return _atOperator;
      totalLength += _right.totalCharacters;
    }

    if (totalLength > pageWidth) return _atOperator;

    return null;
  }
}
