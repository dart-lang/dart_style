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

  // TODO(perf): Most AssignPieces don't allow splitting between [_left] and
  // [_operator]. Also, in the common case where the AssignPiece is for a named
  // argument, then both [_left] and [_operator] will be simple CodePieces. If
  // we used a single piece for both, they can often be concatenated into a
  // single [CodePiece]. We only store [_operator] separately for for-in loops.
  // Consider handling those with a separate Piece class and merging [_left]
  // and [_operator] in this one.

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
    if (state == _blockSplitLeft) constrain(_left!, State.split);
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
    if (_left case var left?) writer.format(left, allowNewlines: allowNewlines);
  }

  void _writeOperator(CodeWriter writer, {bool split = false}) {
    if (_splitBeforeOperator) writer.splitIf(split);

    writer.pushIndent(Indent.expression);
    writer.format(_operator);
    writer.popIndent();

    if (!_splitBeforeOperator) writer.splitIf(split);
  }

  void _writeRight(CodeWriter writer,
      {bool indent = false, bool allowNewlines = true}) {
    if (indent) writer.pushIndent(Indent.expression);
    writer.format(_right, allowNewlines: allowNewlines);
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
      if (left.containsNewline) return _atOperator;

      totalLength += left.totalCharacters;
    }

    totalLength += _operator.totalCharacters;

    if (!_canBlockSplitRight) {
      if (_right.containsNewline) return _atOperator;
      totalLength += _right.totalCharacters;
    }

    if (totalLength > pageWidth) return _atOperator;

    return null;
  }
}
