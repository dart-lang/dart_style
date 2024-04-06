// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

/// Piece for a function call: some name or function expression followed by an
/// argument list with possibly a type argument list between.
///
/// There are three states:
///
/// [State.unsplit] No split anywhere:
///
///     (function + expression)<Type, Args>(argu, ments);
///
/// [_splitArguments] Split the value arguments but nothing else:
///
///     (function + expression)<Type, Args>(
///       argu,
///       ments,
///     );
///
/// [_splitFunction] Split anywhere:
///
///     (function +
///         expression)<
///       Type,
///       Args
///     >(
///       argu,
///       ments,
///     );
///
class CallPiece extends Piece {
  /// Split in the value arguments and nowhere else.
  static const State _splitArguments = State(1, cost: 0);

  /// Split anywhere.
  ///
  /// We use this (with cost 0) instead of [State.split] so that we don't pay
  /// double the cost for splitting the argument ListPiece.
  static const State _splitFunction = State(2, cost: 0);

  /// The function name or expression being called.
  ///
  /// Inside a [ChainPiece], this will include the `.` if it's a method call.
  final Piece _function;

  /// The `<...>` type argument clause, if any.
  final Piece? _typeArguments;

  /// The `(...)` arguments applied to the function.
  final Piece _arguments;

  CallPiece(this._function, this._typeArguments, this._arguments);

  @override
  List<State> get additionalStates => [_splitArguments, _splitFunction];

  @override
  Shape shapeForState(State state) {
    if (state == _splitArguments) return Shape.block;

    // We don't consider splitting in the type arguments and not the value
    // arguments to be block shaped, even though a type arguments clause is
    // also bracket-delimited and block indented. We could, but in the rare
    // times where a type argument list splits, I think it looks better to
    // force the surrounding code to split too. So we disallow:
    //
    //     variable = function<
    //       VeryLong,
    //       TypeArgument,
    //       List
    //     >();
    //
    // And instead choose:
    //
    //     variable =
    //       function<
    //         VeryLong,
    //         TypeArgument,
    //         List
    //       >();
    return Shape.other;
  }

  @override
  void applyShapeConstraints(State state, ConstrainShape constrain) {
    // If only the value arguments split, it's block shaped.
    if (state == _splitArguments) constrain(_arguments, Shape.block);
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_function, allowNewlines: state == _splitFunction);

    if (_typeArguments case var typeArguments?) {
      writer.format(typeArguments, allowNewlines: state == _splitFunction);
    }

    writer.format(_arguments, allowNewlines: state != State.unsplit);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_function);
    if (_typeArguments case var typeArguments?) callback(typeArguments);
    callback(_arguments);
  }
}
