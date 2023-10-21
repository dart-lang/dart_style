// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// Piece for a function type or function-typed parameter.
///
/// Handles splitting between the return type and the rest of the function type.
class FunctionTypePiece extends Piece {
  /// The return type annotation.
  final Piece _returnType;

  /// The rest of the function type signature: name, type parameters,
  /// parameters, etc.
  final Piece _signature;

  FunctionTypePiece(this._returnType, this._signature);

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    // A split inside the return type forces splitting after the return type.
    writer.setAllowNewlines(state == State.split);
    writer.format(_returnType);

    // A split in the type parameters or parameters does not force splitting
    // after the return type.
    writer.setAllowNewlines(true);
    writer.splitIf(state == State.split);

    writer.format(_signature);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_returnType);
    callback(_signature);
  }

  @override
  String toString() => 'FnType';
}
