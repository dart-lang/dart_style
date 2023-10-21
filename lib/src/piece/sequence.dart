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
  final List<Piece> _contents;

  /// The pieces that should have a blank line preserved between them and the
  /// next piece.
  final Set<Piece> _blanksAfter;

  SequencePiece(this._contents, this._blanksAfter);

  /// Whether this sequence has any contents.
  bool get isNotEmpty => _contents.isNotEmpty;

  @override
  void format(CodeWriter writer, State state) {
    for (var i = 0; i < _contents.length; i++) {
      writer.format(_contents[i]);

      if (i < _contents.length - 1) {
        writer.newline(blank: _blanksAfter.contains(_contents[i]));
      }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _contents.forEach(callback);
  }

  @override
  String toString() => 'Sequence';
}
