// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

/// Piece for a collection literal, including any leading `const` keyword and
/// type arguments.
class CollectionPiece extends Piece {
  /// State when a split is allowed anywhere in the collection.
  ///
  /// We use this (with cost 0) instead of [State.split] so that we don't
  /// double count the cost of splitting the elements.
  static const _split = State(1, cost: 0);

  /// The leading `const` keyword, if any.
  final Piece? _constKeyword;

  /// The `<...>` type arguments clause, if any.
  final Piece? _typeArguments;

  /// The delimiters and elements of the collection.
  final Piece _elements;

  CollectionPiece(this._constKeyword, this._typeArguments, this._elements);

  @override
  List<State> get additionalStates => const [_split];

  @override
  Shape shapeForState(State state) {
    if (state == _split) return Shape.block;
    return Shape.other;
  }

  @override
  void applyShapeConstraints(State state, ConstrainShape constrain) {
    if (state == _split) constrain(_elements, Shape.block);
  }

  @override
  void format(CodeWriter writer, State state) {
    if (_constKeyword case var constKeyword?) writer.format(constKeyword);
    if (_typeArguments case var typeArguments?) writer.format(typeArguments);

    writer.format(_elements);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_constKeyword case var constKeyword?) callback(constKeyword);
    if (_typeArguments case var typeArguments?) callback(typeArguments);
    callback(_elements);
  }
}
