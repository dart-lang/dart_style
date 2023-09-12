// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a series of statements or members inside a block or declaration
/// body.
class SequencePiece extends Piece {
  /// The series of members or statements.
  final List<Piece> contents = [];

  /// The pieces that should have a blank line preserved between them and the
  /// next piece.
  final Set<Piece> _blanksAfter = {};

  /// Appends [piece] to the sequence.
  void add(Piece piece) {
    contents.add(piece);
  }

  /// Appends a blank line before the next piece in the sequence.
  void addBlank() {
    if (contents.isEmpty) return;
    _blanksAfter.add(contents.last);
  }

  /// Removes the blank line that has been appended over the last piece.
  void removeBlank() {
    if (contents.isEmpty) return;
    _blanksAfter.remove(contents.last);
  }

  @override
  int get stateCount => 1;

  @override
  void format(CodeWriter writer, int state) {
    for (var i = 0; i < contents.length; i++) {
      writer.format(contents[i]);

      if (i < contents.length - 1) {
        writer.newline(blank: _blanksAfter.contains(contents[i]));
      }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    contents.forEach(callback);
  }

  @override
  String toString() => 'Sequence';
}
