// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A variable declaration.
///
/// Used for local variable declaration statements, top-level variable
/// declarations and field declarations. Also used to handle splitting between
/// a function or function type's return type and the rest of the function.
///
/// Typed and untyped variables have slightly different splitting logic.
/// Untyped variables never split after the keyword but do indent subsequent
/// variables:
///
///     var longVariableName = initializer,
///         anotherVariable = anotherInitializer;
///
/// Typed variables can split that way too:
///
///     String longVariableName = initializer,
///         anotherVariable = anotherInitializer;
///
/// But they can also split after the type annotation. When that happens, the
/// variables aren't indented:
///
///     VeryLongTypeName
///     longVariableName = initializer,
///     anotherVariable = anotherInitializer;
final class VariablePiece extends Piece {
  /// Split between each variable in a multiple variable declaration.
  static const State _betweenVariables = State(1);

  /// Split after the type annotation and between each variable.
  static const State _afterType = State(2, cost: 2);

  /// The leading keywords (`var`, `final`, `late`) and optional type
  /// annotation.
  final Piece _header;

  /// Each individual variable being declared.
  final List<Piece> _variables;

  /// Whether the variable declaration has a type annotation.
  final bool _hasType;

  /// Creates a [VariablePiece].
  ///
  /// The [hasType] parameter should be `true` if the variable declaration has
  /// a type annotation.
  VariablePiece(this._header, this._variables, {required bool hasType})
      : _hasType = hasType;

  @override
  List<State> get additionalStates => [
        if (_variables.length > 1) _betweenVariables,
        if (_hasType) _afterType,
      ];

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (child == _header) {
      return state != State.unsplit;
    } else {
      return _variables.length == 1 || state != State.unsplit;
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);

    // If we split at the variables (but not the type), then indent the
    // variables and their initializers.
    if (state == _betweenVariables) writer.pushIndent(Indent.expression);

    // Split after the type annotation.
    writer.splitIf(state == _afterType);

    for (var i = 0; i < _variables.length; i++) {
      // Split between variables.
      if (i > 0) writer.splitIf(state != State.unsplit);

      writer.format(_variables[i]);
    }

    if (state == _betweenVariables) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    _variables.forEach(callback);
  }

  @override
  String get debugName => 'Var';
}
