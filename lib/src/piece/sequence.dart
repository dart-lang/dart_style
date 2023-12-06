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
  final List<SequenceElement> _elements;

  SequencePiece(this._elements);

  /// Whether this sequence has any contents.
  bool get isNotEmpty => _elements.isNotEmpty;

  @override
  void format(CodeWriter writer, State state) {
    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];
      writer.format(element.piece);

      for (var comment in element.hangingComments) {
        writer.space();
        writer.format(comment);
      }

      if (i < _elements.length - 1) {
        writer.newline(
            blank: element.blankAfter, indent: _elements[i + 1].indent);
      }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    for (var element in _elements) {
      callback(element.piece);
      for (var comment in element.hangingComments) {
        callback(comment);
      }
    }
  }

  @override
  String get debugName => 'Seq';
}

/// An element inside a [SequencePiece].
///
/// Tracks the underlying [Piece] along with surrounding whitespace.
class SequenceElement {
  /// The number of spaces of indentation on the line before this element,
  /// relative to the surrounding [Piece].
  final int indent;

  /// The [Piece] for the element.
  final Piece piece;

  /// The comments that should appear at the end of this element's line.
  final List<Piece> hangingComments = [];

  /// Whether there should be a blank line after this element.
  bool blankAfter = false;

  SequenceElement(this.indent, this.piece);
}
