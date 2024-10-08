// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a type parameter and its bound.
///
/// Handles not splitting before `extends` if we can split inside the bound's
/// own type arguments, or splitting before `extends` if that isn't enough to
/// get it to fit.
final class TypeParameterBoundPiece extends Piece {
  /// Split inside the type arguments of the bound, but not at `extends`, as in:
  ///
  ///     class C<
  ///       T extends Map<
  ///         LongKeyType,
  ///         LongValueType
  ///       >
  ///     >{}
  static const State _insideBound = State(1);

  /// Split at `extends`, like:
  ///
  ///     class C<
  ///       LongTypeParameters
  ///           extends LongBoundType
  ///     >{}
  static const State _beforeExtends = State(2);

  /// The type parameter name.
  final Piece _typeParameter;

  /// The bound with the preceding `extends` keyword.
  final Piece _bound;

  TypeParameterBoundPiece(this._typeParameter, this._bound);

  @override
  List<State> get additionalStates => const [_insideBound, _beforeExtends];

  @override
  bool allowNewlineInChild(State state, Piece child) => switch (state) {
        State.unsplit => false,
        _insideBound => child == _bound,
        _beforeExtends => true,
        _ => throw ArgumentError('Unexpected state.'),
      };

  @override
  void format(CodeWriter writer, State state) {
    if (state == _beforeExtends) writer.pushIndent(Indent.expression);
    writer.format(_typeParameter);
    writer.splitIf(state == _beforeExtends);
    writer.format(_bound);
    if (state == _beforeExtends) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_typeParameter);
    callback(_bound);
  }
}
