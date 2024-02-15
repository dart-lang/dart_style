// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../piece/adjacent.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import 'delimited_list_builder.dart';
import 'piece_factory.dart';
import 'sequence_builder.dart';

/// Incrementally builds an [AdjacentPiece].
///
/// Can also be used to attach metadata annotations to the [Piece] being built.
class AdjacentBuilder {
  final PieceFactory _visitor;

  final List<Piece> _metadataPieces = [];

  /// Whether the annotations added by a call to [metadata] should be allowed
  /// on the same line as the code they annotate, or whether a mandatory
  /// newline should be inserted after each annotation.
  bool _isMetadataInline = false;

  /// The series of adjacent pieces.
  final List<Piece> _pieces = [];

  AdjacentBuilder(this._visitor);

  /// Creates pieces for all of the annotations in [metadata].
  ///
  /// When this builder is built, if there are any annotations, the returned
  /// Piece will contain the annotation pieces followed by the [AdjacentPiece]
  /// being built.
  void metadata(List<Annotation> metadata, {bool inline = false}) {
    _isMetadataInline = inline;

    for (var annotation in metadata) {
      _metadataPieces.add(_visitor.nodePiece(annotation));
    }
  }

  /// Yields a new piece containing all of the pieces added to or created by
  /// this builder. The caller must ensure it doesn't build an empty piece.
  ///
  /// Also clears the builder's list of pieces so that this builder can be
  /// reused to build more pieces.
  Piece build() {
    assert(_pieces.isNotEmpty);

    var result = _flattenPieces();
    _pieces.clear();

    // If there is metadata, wrap the AdjacentPiece in another piece containing
    // the annotations first.
    if (_metadataPieces.isNotEmpty) {
      if (_isMetadataInline) {
        var list = DelimitedListBuilder(
            _visitor,
            const ListStyle(
              commas: Commas.none,
              spaceWhenUnsplit: true,
            ));

        for (var piece in _metadataPieces) {
          list.add(piece);
        }

        list.add(result);
        result = list.build();
      } else {
        var sequence = SequenceBuilder(_visitor);
        for (var piece in _metadataPieces) {
          sequence.add(piece);
        }

        sequence.add(result);
        result = sequence.build(forceSplit: true);
      }

      _metadataPieces.clear();
    }

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
    var flattened = <Piece>[];

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
