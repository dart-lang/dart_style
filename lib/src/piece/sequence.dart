// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a series of statements or members inside a block or declaration
/// body or at the top level of a program.
///
/// Constructed using a [SequenceBuilder].
class SequencePiece extends Piece {
  /// The series of members or statements.
  final List<SequenceElementPiece> _elements;

  SequencePiece(this._elements);

  @override
  void format(CodeWriter writer, State state) {
    writer.pushIndent(Indent.none);

    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];

      writer.format(element, separate: true);

      if (i < _elements.length - 1) {
        writer.popIndent();
        writer.pushIndent(_elements[i + 1]._indent);
        writer.newline(blank: element.blankAfter);
      }
    }

    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    for (var element in _elements) {
      callback(element);
    }
  }

  /// If there are multiple elements, there are newlines between them.
  @override
  bool calculateContainsHardNewline() => _elements.length > 1;

  @override
  String get debugName => 'Seq';
}

/// A piece for a non-empty brace-delimited series of statements or members
/// inside a block or declaration body.
///
/// Unlike [ListPiece], always splits between the elements.
///
/// Constructed using a [SequenceBuilder].
class BlockPiece extends Piece {
  /// The opening delimiter.
  final Piece _leftBracket;

  /// The series of members or statements.
  final SequencePiece _elements;

  /// The closing delimiter.
  final Piece _rightBracket;

  BlockPiece(this._leftBracket, this._elements, this._rightBracket);

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_leftBracket);
    writer.pushIndent(Indent.block);
    writer.newline();
    writer.format(_elements);
    writer.popIndent();
    writer.newline();
    writer.format(_rightBracket);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_leftBracket);
    callback(_elements);
    callback(_rightBracket);
  }

  /// A [BlockPiece] is never empty and always splits between the delimiters.
  @override
  bool calculateContainsHardNewline() => true;

  @override
  String get debugName => 'Block';
}

/// An element inside a [SequencePiece].
///
/// Tracks the underlying [Piece] along with surrounding whitespace.
class SequenceElementPiece extends Piece {
  /// The number of spaces of indentation on the line before this element,
  /// relative to the surrounding [Piece].
  final int _indent;

  /// The [Piece] for the element.
  final Piece piece;

  /// The comments that should appear at the end of this element's line.
  final List<Piece> hangingComments = [];

  /// Whether there should be a blank line after this element.
  bool blankAfter = false;

  SequenceElementPiece(this._indent, this.piece);

  @override
  void format(CodeWriter writer, State state) {
    writer.format(piece);

    for (var comment in hangingComments) {
      writer.space();
      writer.format(comment);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(piece);
    for (var comment in hangingComments) {
      callback(comment);
    }
  }

  @override
  String get debugName => 'SeqElem';
}
