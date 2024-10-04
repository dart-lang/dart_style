// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A constructor declaration.
///
/// This is somewhat similar to [FunctionPiece], but constructor initializers
/// add a lot of complexity. In particular, there are constraints between how
/// the parameter list is allowed to split and how the initializer list is
/// allowed to split. Only a few combinations of splits are allowed:
///
/// [State.unsplit] No splits at all, in the parameters or initializers.
///
///       SomeClass(param) : a = 1, b = 2;
///
/// [_splitBeforeInitializers] Split before the `:` and between the
/// initializers but not in the parameters.
///
///       SomeClass(param)
///         : a = 1,
///           b = 2;
///
/// [_splitBetweenInitializers] Split between the initializers but not before
/// the `:`. This state should only be chosen when the parameters split. If
/// there are no parameters, this state is excluded.
///
///       SomeClass(
///         param
///       ) : a = 1,
///           b = 2;
///
/// In addition, this piece deals with indenting initializers appropriately
/// based on whether the parameter list has a `]` or `}` before the `)`. If
/// there are optional parameters, then initializers after the first are
/// indented one space more to line up with the first initializer:
///
///     SomeClass(
///       mandatory,
///     ) : firstInitializer = 1,
///         second = 2;
///     // ^ Four spaces of indentation.
///
///     SomeClass([
///       optional,
///     ]) : firstInitializer = 1,
///          second = 2;
///     //  ^ Five spaces of indentation.
final class ConstructorPiece extends Piece {
  static const _splitBeforeInitializers = State(1, cost: 1);

  static const _splitBetweenInitializers = State(2, cost: 2);

  /// True if there are parameters or comments inside the parameter list.
  ///
  /// If so, then we allow splitting the parameter list while leaving the `:`
  /// on the same line as the `)`.
  final bool _canSplitParameters;

  /// Whether the parameter list contains a `]` or `}` closing delimiter before
  /// the `)`.
  final bool _hasOptionalParameter;

  /// The leading keywords, class name, and constructor name.
  final Piece _header;

  /// The constructor parameter list.
  final Piece _parameters;

  /// If this is a redirecting constructor, the redirection clause.
  final Piece? _redirect;

  /// If there are initializers, the `:` before them.
  final Piece? _initializerSeparator;

  /// The constructor initializers, if there are any.
  final Piece? _initializers;

  /// The constructor body.
  final Piece _body;

  ConstructorPiece(this._header, this._parameters, this._body,
      {required bool canSplitParameters,
      required bool hasOptionalParameter,
      Piece? redirect,
      Piece? initializerSeparator,
      Piece? initializers})
      : _canSplitParameters = canSplitParameters,
        _hasOptionalParameter = hasOptionalParameter,
        _redirect = redirect,
        _initializerSeparator = initializerSeparator,
        _initializers = initializers;

  @override
  List<State> get additionalStates => [
        if (_initializers != null) _splitBeforeInitializers,
        if (_canSplitParameters && _initializers != null)
          _splitBetweenInitializers
      ];

  /// Apply constraints between how the parameters may split and how the
  /// initializers may split.
  @override
  void applyConstraints(State state, Constrain constrain) {
    // If there are no initializers, the parameters can do whatever.
    if (_initializers case var initializers?) {
      switch (state) {
        case State.unsplit:
          // All parameters and initializers on one line.
          constrain(_parameters, State.unsplit);
          constrain(initializers, State.unsplit);

        case _splitBeforeInitializers:
          // Only split before the `:` when the parameters fit on one line.
          constrain(_parameters, State.unsplit);
          constrain(initializers, State.split);

        case _splitBetweenInitializers:
          // Split both the parameters and initializers and put the `) :` on
          // its own line.
          constrain(_parameters, State.split);
          constrain(initializers, State.split);
      }
    }
  }

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (child == _body) return true;

    // If there's a newline in the header or parameters (like a line comment
    // after the `)`), then don't allow the initializers to remain unsplit.
    return _initializers == null || state != State.unsplit;
  }

  @override
  bool containsNewline(State state) =>
      state == _splitBeforeInitializers || super.containsNewline(state);

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);
    writer.format(_parameters);

    if (_redirect case var redirect?) {
      writer.space();
      writer.format(redirect);
    }

    if (_initializers case var initializers?) {
      writer.pushIndent(Indent.block);
      writer.splitIf(state == _splitBeforeInitializers);

      writer.format(_initializerSeparator!);
      writer.space();

      // Indent subsequent initializers past the `:`.
      if (_hasOptionalParameter && state == _splitBetweenInitializers) {
        writer.pushIndent(Indent.initializerWithOptionalParameter);
      } else {
        writer.pushIndent(Indent.initializer);
      }

      writer.format(initializers);
      writer.popIndent();
      writer.popIndent();
    }

    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    callback(_parameters);
    if (_redirect case var redirect?) callback(redirect);
    if (_initializerSeparator case var separator?) callback(separator);
    if (_initializers case var initializers?) callback(initializers);
    callback(_body);
  }

  @override
  String get debugName => 'Ctor';
}
