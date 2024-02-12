// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// Piece for a function declaration, function type, or function-typed
/// parameter.
///
/// Handles splitting between the return type and the rest of the function.
class FunctionPiece extends Piece {
  /// The return type annotation, if any.
  final Piece? _returnType;

  /// The rest of the function type signature: name, type parameters,
  /// parameters, etc.
  final Piece _signature;

  /// If this is a function declaration with a (non-empty `;`) body, the body.
  final Piece? _body;

  /// Whether the return type is a function type.
  ///
  /// When it is, allow splitting fairly cheaply because the return type is
  /// usually pretty big and looks good on its own line, or at least better
  /// then splitting inside the return type's parameter list. Prefers:
  ///
  ///     Function(int x, int y)
  ///     returnFunction() { ... }
  ///
  /// Over:
  ///
  ///     Function(
  ///       int x,
  ///       int y,
  ///     ) returnFunction() { ... }
  ///
  /// If the return type is *not* a function type, is almost always looks worse
  /// to split at the return type, so make that high cost.
  final bool _isReturnTypeFunctionType;

  FunctionPiece(this._returnType, this._signature,
      {required bool isReturnTypeFunctionType, Piece? body})
      : _body = body,
        _isReturnTypeFunctionType = isReturnTypeFunctionType;

  @override
  List<State> get additionalStates => [if (_returnType != null) State.split];

  @override
  int stateCost(State state) {
    if (state == State.split) return _isReturnTypeFunctionType ? 1 : 4;
    return super.stateCost(state);
  }

  @override
  void format(CodeWriter writer, State state) {
    if (_returnType case var returnType?) {
      // A split inside the return type forces splitting after the return type.
      writer.pushAllowNewlines(state == State.split);
      writer.format(returnType);
      writer.popAllowNewlines();

      // A split in the type parameters or parameters does not force splitting
      // after the return type.
      writer.pushAllowNewlines(true);
      writer.splitIf(state == State.split);
      writer.popAllowNewlines();
    }

    writer.format(_signature);

    if (_body case var body?) writer.format(body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_returnType case var returnType?) callback(returnType);
    callback(_signature);
    if (_body case var body?) callback(body);
  }

  @override
  String get debugName => 'Fn';
}
