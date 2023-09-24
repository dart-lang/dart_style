// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a series of statements or members inside a block or declaration
/// body.
///
/// Usually constructed using a [SequenceBuilder].
class SequencePiece extends Piece {
  /// The series of members or statements.
  final List<Piece> contents;

  /// The pieces that should have a blank line preserved between them and the
  /// next piece.
  final Set<Piece> _blanksAfter;

  SequencePiece(this.contents, this._blanksAfter);

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
