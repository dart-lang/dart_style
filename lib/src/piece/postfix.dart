// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a series of pieces that all split before or not.
///
/// For example, an [ImportPiece] uses a [PostfixPiece] for the list of
/// configurations:
///
///     import 'foo.dart'
///       if (a) 'foo_a.dart'
///       if (b) 'foo_a.dart'
///       if (c) 'foo_a.dart';
///
/// We either split before every `if` or none of them, and the [PostfixPiece]
/// contains a piece for each configuration to model that.
class PostfixPiece extends Piece {
  final List<Piece> pieces;

  PostfixPiece(this.pieces);

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    // If any of the operands split, then force the postfix sequence to split
    // too.
    // TODO(tall): This will need to be revisited when we use PostfixPiece for
    // actual postfix operators where this isn't always desired.
    if (state == State.unsplit) writer.setAllowNewlines(false);

    writer.pushIndent(Indent.expression);

    for (var piece in pieces) {
      writer.splitIf(state == State.split);
      writer.format(piece);
    }

    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    pieces.forEach(callback);
  }
}
