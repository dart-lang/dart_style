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

  // TODO(perf): These two fields are purely optimizations. They avoid
  // considering states that we know syntactically will never be valid because
  // the operand can't block format anyway. Implementing these correctly is
  // subtle because it means we need to make sure that any AST node that could
  // possibly block format must set this to true.
  //
  // This seems to somewhat help the perf lost in adding support for SplitStyle,
  // but it's still pretty slow. Committing for now so I don't lose it, but
  // ideally these (and the extension methods in ast_extensions.dart) would go
  // away.

  // TODO: Should be able to get rid of these and rely on the child pieces
  // telling us whether or not they block split, but it seems to still be
  // useful for indentation somehow.
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
  // For now, we do not implement this special case behavior. Once more of the
  // language is implemented in the new back end and we can run the formatter
  // on a large corpus of code, we can try it out and see if the special case
  // behavior is worth it.

  @override
  List<State> get additionalStates => [
        if (_canBlockSplitLeft && _canBlockSplitRight) _blockSplitBoth,
        if (_canBlockSplitRight) _blockSplitRight,
        if (_canBlockSplitLeft) _blockSplitLeft,
        _headerRight,
        _atOperator
      ];

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
        _writeRight(writer, require: SplitType.header);

      case _blockSplitRight:
        _writeLeft(writer);
        _writeOperator(writer);
        _writeRight(writer, require: SplitType.block);

      case _blockSplitBoth:
        _writeLeft(writer, requireBlock: true);
        _writeOperator(writer);
        _writeRight(writer, require: SplitType.block);

      case _blockSplitLeft:
        _writeLeft(writer, requireBlock: true);
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

  void _writeLeft(CodeWriter writer,
      {bool allowNewlines = true, bool requireBlock = false}) {
    if (_left case var left?) {
      var leftSplit = writer.format(left, allowNewlines: allowNewlines);
      if (requireBlock && leftSplit != SplitType.block) {
        writer.invalidate(left);
      }
    }
  }

  void _writeOperator(CodeWriter writer,
      {bool split = false, bool allowNewlines = true}) {
    if (_splitBeforeOperator) writer.splitIf(split);
    writer.format(_operator, allowNewlines: allowNewlines);
    if (!_splitBeforeOperator) writer.splitIf(split);
  }

  void _writeRight(CodeWriter writer,
      {bool allowNewlines = true, SplitType? require}) {
    var rightSplit = writer.format(_right, allowNewlines: allowNewlines);
    if (require != null && rightSplit != require) {
      writer.invalidate(_right);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_left case var left?) callback(left);
    callback(_operator);
    callback(_right);
  }
}
