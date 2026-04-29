// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for an `as` or `is` expression.
final class TypeTestPiece extends Piece {
  /// Allow the expression to block split.
  ///
  /// Unlike most pieces that allow block splitting, the cost here isn't zero
  /// because we would prefer to split at `=` if it lets the entire type test
  /// expression fit on one line:
  ///
  ///     variable =
  ///         function(argument) as Type;
  static const State _blockSplitExpression = State(1);

  /// The expression being tested or cast.
  final Piece _expression;

  /// The `as`, `is`, or `is!` operator.
  final Piece _operator;

  /// The type being tested against or cast to.
  final Piece _type;

  /// Whether the expression can be block formatted.
  final bool _canBlockSplit;

  TypeTestPiece(
    this._expression,
    this._operator,
    this._type, {
    bool canBlockSplit = false,
  }) : _canBlockSplit = canBlockSplit;

  @override
  List<State> get additionalStates => [
    if (_canBlockSplit) _blockSplitExpression,
    State.split,
  ];

  @override
  void format(CodeWriter writer, State state) {
    if (state == State.split) writer.pushIndent(Indent.expression);

    writer.format(_expression);
    writer.splitIf(state == State.split);
    writer.format(_operator);
    writer.space();
    writer.format(_type);

    if (state == State.split) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_expression);
    callback(_operator);
    callback(_type);
  }

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) => switch (state) {
    State.unsplit => Shape.onlyInline,
    _blockSplitExpression when child == _expression => Shape.onlyBlock,
    _ => Shape.all,
  };
}
