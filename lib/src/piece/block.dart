// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';
import 'sequence.dart';

/// A piece for a series of statements or members inside a block or declaration
/// body.
class BlockPiece extends Piece {
  /// The opening delimiter.
  final Piece leftBracket;

  /// The sequence of members, statements, and sequence-level comments.
  final SequencePiece contents;

  /// The closing delimiter.
  final Piece rightBracket;

  /// If [alwaysSplit] is true, then the block should always split its contents.
  /// This is true for most blocks, but false for enums and blocks containing
  /// only inline block comments.
  BlockPiece(this.leftBracket, this.contents, this.rightBracket,
      {bool alwaysSplit = true}) {
    if (alwaysSplit) pin(State.split);
  }

  @override
  List<State> get additionalStates => [if (contents.isNotEmpty) State.split];

  @override
  void format(CodeWriter writer, State state) {
    writer.format(leftBracket);

    if (state == State.split) {
      if (contents.isNotEmpty) {
        writer.newline(indent: Indent.block);
        writer.format(contents);
      }

      writer.newline(indent: Indent.none);
    } else {
      writer.setAllowNewlines(false);
      writer.format(contents);
    }

    writer.format(rightBracket);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(leftBracket);
    callback(contents);
    callback(rightBracket);
  }

  @override
  String toString() => 'Block';
}
