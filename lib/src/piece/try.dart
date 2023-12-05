// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a try statement.
class TryPiece extends Piece {
  final List<_TrySectionPiece> _sections = [];

  void add(Piece header, Piece block) {
    _sections.add(_TrySectionPiece(header, block));
  }

  @override
  void format(CodeWriter writer, State state) {
    for (var i = 0; i < _sections.length; i++) {
      var section = _sections[i];
      writer.format(section.header);
      writer.space();
      writer.format(section.body);

      // Adds the space between the end of a block and the next header.
      if (i < _sections.length - 1) {
        writer.space();
      }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    for (var section in _sections) {
      callback(section.header);
      callback(section.body);
    }
  }
}

/// A section for a try.
///
/// This could be a try, an on/catch, or a finally section. They are all
/// formatted similarly.
class _TrySectionPiece {
  final Piece header;
  final Piece body;

  _TrySectionPiece(this.header, this.body);
}
