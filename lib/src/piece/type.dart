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
  final ClausesPiece? _clauses;

  /// The `native` clause, if any, and the type body.
  final Piece _body;

  /// Whether the type has a `{ ... }` body or just a `;` at the end (for a
  /// mixin application class).
  final bool _hasBody;

  TypePiece(this._header, this._clauses, this._body, {required bool hasBody})
      : _hasBody = hasBody;

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_header);
    if (_clauses case var clauses?) writer.format(clauses);
    if (_hasBody) writer.space();
    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    if (_clauses case var clauses?) callback(clauses);
    callback(_body);
  }
}
