// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// Piece for a type declaration with a body containing members.
///
/// Used for class, enum, and extension declarations.
final class TypePiece extends Piece {
  /// The leading keywords and modifiers, type name, type parameters, and any
  /// other `extends`, `with`, etc. clauses.
  final Piece _header;

  /// The type body.
  final Piece _body;

  /// What kind of body the type has.
  final TypeBodyType _bodyType;

  TypePiece(this._header, this._body, {required TypeBodyType bodyType})
    : _bodyType = bodyType;

  @override
  List<State> get additionalStates => [
    if (_bodyType == TypeBodyType.list) State.split,
  ];

  @override
  void applyConstraints(State state, Constrain constrain) {
    // If the body may or may not split, force it to split when the header does.
    if (state == State.split) constrain(_body, State.split);
  }

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    if (child == _body) return Shape.all;

    // If the body may or may not split, then a newline in the header or
    // clauses forces the body to split.
    return Shape.anyIf(_bodyType != TypeBodyType.list || state == State.split);
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);
    if (_bodyType != TypeBodyType.semicolon) writer.space();
    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    callback(_body);
  }
}

/// Piece for a type with a primary constructor (or extension type
/// representation type) in the header.
///
/// These use a separate [Piece] class to handle the interactions between
/// splitting in the constructor parameter list, and/or any subsequent clauses
/// in the header. There are a few ways it can split with some constraints
/// between them:
///
/// [State.unsplit] Everything in the header on one line:
///
///     class C(int x) extends S {
///       body() {}
///     }
///
/// [_beforeClauses] Split before every clause including the first. This is
/// only allowed when the parameter list does not split:
///
///     class C(int x, int y)
///         extends Super
///         implements I {
///       body() {}
///     }
///
/// [_inlineClauses] The parameter list must split and the clauses all fit on
/// one line between the `)` and the beginning of the body:
///
///     class C(
///       int x,
///       int y,
///     ) extends S {
///       body() {}
///     }
///
/// [_betweenClauses] The parameter list must split and all but the first clause
/// start their own lines:
///
///     class C(
///       int x,
///       int y,
///     ) extends S
///         implements I {
///       body() {}
///     }
///
/// [State.split] Similar to [_beforeClauses] but allows the parameter list to
/// split too. Mainly so that if the constraints of the previous states can't
/// otherwise be solved, then solver can still pick an invalid solution.
///
/// These constraints are designed to mostly avoid the clauses awkwardly
/// hanging out on their own lines when the parameter splits as in:
///
///     class C(
///       int x,
///       int y,
///     )
///         extends S {
///       body() {}
///     }
final class PrimaryTypePiece extends Piece {
  /// Split before all clauses and don't allow the parameter list to split.
  static const State _beforeClauses = State(1);

  /// Keep all clauses inline and force the parameter list to split.
  static const State _inlineClauses = State(2);

  /// Split before every clause but the first.
  static const State _betweenClauses = State(3);

  /// The leading keywords and modifiers, type name, type parameters, and any
  /// other `extends`, `with`, etc. clauses.
  final Piece _header;

  /// The constructor's formal parameter list.
  final Piece _parameters;

  /// The `extends`, `with`, `implements`, etc. clauses, if any.
  final List<Piece> _clauses;

  /// The type body.
  final Piece _body;

  /// What kind of body the type has.
  final TypeBodyType _bodyType;

  PrimaryTypePiece(
    this._header,
    this._parameters,
    this._clauses,
    this._body,
    this._bodyType,
  );

  @override
  List<State> get additionalStates => [
    if (_clauses.isNotEmpty) ...[_beforeClauses, _inlineClauses],
    _betweenClauses,
    State.split,
  ];

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    if (child == _header) return Shape.all;

    switch (state) {
      case State.unsplit:
        // We only restrict the header from splitting.
        if (child != _body) return Shape.onlyInline;

      case _beforeClauses:
        // The parameters can't split and the clauses can.
        if (child == _parameters) return Shape.onlyInline;

      case _inlineClauses:
        // The parameters must split and the clauses can't.
        if (child == _parameters) return Shape.onlyBlock;
        if (_clauses.contains(child)) return Shape.onlyInline;

      case _betweenClauses:
        // The parameters must split and the clauses can.
        if (child == _parameters) return Shape.onlyBlock;
    }

    return Shape.all;
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);
    writer.format(_parameters);

    // Indent all of the clauses if any will start a line.
    var indent =
        state == _beforeClauses ||
        state == _betweenClauses && _clauses.length > 1 ||
        state == State.split;
    if (indent) writer.pushIndent(Indent.infix);

    for (var clause in _clauses) {
      writer.splitIf(
        state == _beforeClauses ||
            state == _betweenClauses && clause != _clauses.first ||
            state == State.split,
      );
      writer.format(clause);
    }

    if (indent) writer.popIndent();

    if (_bodyType != TypeBodyType.semicolon) writer.space();
    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    callback(_parameters);
    for (var clause in _clauses) {
      callback(clause);
    }
    callback(_body);
  }
}

/// What kind of body is used for the type.
enum TypeBodyType {
  /// An always-split block body, as in a class declaration.
  block,

  /// A curly-brace delimited list that may or may not split.
  ///
  /// Used for enums with constants but no members.
  list,

  /// A single `;` body, used for mixin application classes.
  semicolon,
}
