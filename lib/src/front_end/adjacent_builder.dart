// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../piece/adjacent.dart';
import '../piece/piece.dart';
import 'piece_factory.dart';

/// Incrementally builds an [AdjacentPiece].
class AdjacentBuilder {
  final PieceFactory _visitor;

  /// The series of adjacent pieces.
  final List<Piece> _pieces = [];

  AdjacentBuilder(this._visitor);

  /// Yields a new piece containing all of the pieces added to or created by
  /// this builder. The caller must ensure it doesn't build an empty piece.
  ///
  /// Also clears the builder's list of pieces so that this builder can be
  /// reused to build more pieces.
  Piece build() {
    assert(_pieces.isNotEmpty);

    var result = _flattenPieces();
    _pieces.clear();

    return result;
  }

  /// Adds [piece] to this builder.
  void add(Piece piece) {
    _pieces.add(piece);
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// If [lexeme] is given, uses that for the token's lexeme instead of its own.
  ///
  /// Does nothing if [token] is `null`. If [spaceBefore] is `true`, writes a
  /// space before the token, likewise with [spaceAfter].
  void token(Token? token,
      {bool spaceBefore = false, bool spaceAfter = false, String? lexeme}) {
    if (token == null) return;

    if (spaceBefore) space();
    add(_visitor.pieces.tokenPiece(token, lexeme: lexeme));
    if (spaceAfter) space();
  }

  /// Writes any comments that appear before [token], which will be discarded.
  ///
  /// Used to ensure comments before a discarded token are preserved.
  void commentsBefore(Token? token) {
    if (token == null) return;

    var piece = _visitor.pieces.writeCommentsBefore(token);
    if (piece != null) add(piece);
  }

  /// Writes an optional modifier that precedes other code.
  void modifier(Token? keyword) {
    token(keyword, spaceAfter: true);
  }

  /// Visits [node] if not `null` and adds the resulting [Piece] to this
  /// builder.
  void visit(AstNode? node,
      {bool spaceBefore = false,
      bool commaAfter = false,
      bool spaceAfter = false}) {
    if (node == null) return;

    if (spaceBefore) space();
    add(_visitor.nodePiece(node, commaAfter: commaAfter));
    if (spaceAfter) space();
  }

  /// Appends a space before the previous piece and the next one.
  void space() {
    _pieces.add(SpacePiece());
  }

  /// Removes redundant [AdjacentPiece] wrappers from [_pieces].
  Piece _flattenPieces() {
    List<Piece> flattened = [];

    void traverse(List<Piece> pieces) {
      for (var piece in pieces) {
        if (piece is AdjacentPiece) {
          traverse(piece.pieces);
        } else {
          flattened.add(piece);
        }
      }
    }

    traverse(_pieces);

    // If there's only one piece, don't wrap it in a pointless AdjacentPiece.
    if (flattened.length == 1) return flattened[0];

    return AdjacentPiece(flattened);
  }
}
