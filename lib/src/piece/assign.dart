// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for an assignment-like construct:
///
/// - Assignment (`=`, `+=`, etc.)
/// - Named arguments (`:`)
/// - Map entries (`:`)
/// - Record fields (`:`)
/// - Expression function bodies (`=>`)
///
/// Unlike other infix operators, these have some special formatting:
///
/// [State.unsplit] No split at all:
///
///     var x = 123;
///
/// This state also allows splitting the right side if block shaped:
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
/// [_blockOrHeadlineSplitRight] Require the right-hand side to be block or
/// headline shaped and allow the left-side to expression split as in:
///
///     var (variable &&
///         anotherVariable) = [
///       element,
///     ];
///
/// [State.split] Split at the `=` or `in` operator and allow expression
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
final class AssignPiece extends Piece {
  /// Allow the right-hand side to block split.
  static const State _blockOrHeadlineSplitRight = State(1, cost: 0);

  /// Force the left-hand side to block split and allow the right-hand side to
  /// split.
  static const State _blockSplitLeft = State(2);

  /// The left-hand side of the operation and the operator itself.
  final Piece _left;

  /// The right-hand side of the operation.
  final Piece _right;

  /// Whether the piece should have a cost for splitting at the operator.
  ///
  /// Usually true because it's generally better to block split inside the
  /// operands when possible. But false for `=>` when the expression has a form
  /// where we'd rather keep the expression itself unsplit as in:
  ///
  ///     // Don't avoid split:
  ///     makeStuff() => [
  ///       element,
  ///       element,
  ///     ];
  ///
  ///     // Avoid split:
  ///     doThing() =>
  ///       thingToDo(argument, argument);
  final bool _avoidSplit;

  AssignPiece(this._left, this._right, {bool avoidSplit = true})
    : _avoidSplit = avoidSplit;

  @override
  List<State> get additionalStates => [
    _blockOrHeadlineSplitRight,
    _blockSplitLeft,
    State.split,
  ];

  @override
  int stateCost(State state) => switch (state) {
    State.split => _avoidSplit ? 1 : 0,
    _ => super.stateCost(state),
  };

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    return switch (state) {
      State.unsplit => Shape.onlyInline,
      _blockSplitLeft when child == _left => Shape.onlyBlock,
      _blockSplitLeft when child == _right => const {Shape.inline, Shape.other},
      _blockOrHeadlineSplitRight when child == _right => const {
        Shape.block,
        Shape.headline,
      },
      _ => Shape.all,
    };
  }

  @override
  void format(CodeWriter writer, State state) {
    if (state == State.split) {
      // When splitting at the operator, indent the operands.
      writer.pushIndent(Indent.expression);

      // Treat a split `=` as potentially headline-shaped if the LHS doesn't
      // split. Allows:
      //
      //     variable = another =
      //         'split at second "="';
      writer.setShapeMode(ShapeMode.beforeHeadline);
      writer.format(_left);
      writer.setShapeMode(ShapeMode.afterHeadline);

      writer.newline();
      writer.popIndent();
      writer.pushIndent(Indent.assignment);
      writer.format(_right);
      writer.popIndent();
    } else {
      writer.format(_left);
      writer.space();
      writer.format(_right);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_left);
    callback(_right);
  }
}
