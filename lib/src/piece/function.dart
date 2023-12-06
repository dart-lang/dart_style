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
  static const _splitAfterReturnType = State(1, cost: 2);

  /// The return type annotation, if any.
  final Piece? _returnType;

  /// The rest of the function type signature: name, type parameters,
  /// parameters, etc.
  final Piece _signature;

  /// If this is a function declaration with a (non-empty `;`) body, the body.
  final Piece? _body;

  /// Whether we should write a space between the function signature and body.
  ///
  /// This is `true` for most bodies except for empty function bodies, like:
  ///
  /// ```
  /// class C {
  ///   C();
  ///   // ^ No space before `;`.
  /// }
  /// ```
  final bool _spaceBeforeBody;

  FunctionPiece(this._returnType, this._signature,
      {Piece? body, bool spaceBeforeBody = false})
      : _body = body,
        _spaceBeforeBody = spaceBeforeBody;

  @override
  List<State> get additionalStates =>
      [if (_returnType != null) _splitAfterReturnType];

  @override
  void format(CodeWriter writer, State state) {
    if (_returnType case var returnType?) {
      // A split inside the return type forces splitting after the return type.
      writer.setAllowNewlines(state == _splitAfterReturnType);

      writer.format(returnType);

      // A split in the type parameters or parameters does not force splitting
      // after the return type.
      writer.setAllowNewlines(true);
      writer.splitIf(state == _splitAfterReturnType);
    }

    writer.format(_signature);
    if (_body case var body?) {
      if (_spaceBeforeBody) writer.space();
      writer.format(body);
    }
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
