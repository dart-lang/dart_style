// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'clause.dart';
import 'piece.dart';

/// Piece for a type declaration with a body containing members.
///
/// Used for class, enum, and extension declarations.
class TypePiece extends Piece {
  /// The leading keywords and modifiers, type name, and type parameters.
  final Piece _header;

  /// The `extends`, `with`, and/or `implements` clauses, if there are any.
  final ClausePiece? _clauses;

  /// The `native` clause, if any, and the type body.
  final Piece _body;

  /// What kind of body the type has.
  final TypeBodyType _bodyType;

  TypePiece(this._header, this._clauses, this._body,
      {required TypeBodyType bodyType})
      : _bodyType = bodyType;

  @override
  List<State> get additionalStates =>
      [if (_bodyType == TypeBodyType.list) State.split];

  @override
  void applyConstraints(State state, Constrain constrain) {
    // If the body may or may not split, force it to split when the header does.
    if (state == State.split) constrain(_body, State.split);
  }

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (child == _body) return true;

    // If the body may or may not split, then a newline in the header or
    // clauses forces the body to split.
    return _bodyType != TypeBodyType.list || state == State.split;
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);
    if (_clauses case var clauses?) {
      writer.format(clauses);
    }

    if (_bodyType != TypeBodyType.semicolon) writer.space();
    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    if (_clauses case var clauses?) callback(clauses);
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
