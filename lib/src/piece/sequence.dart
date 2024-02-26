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
  /// The opening delimiter, if any.
  final Piece? _leftBracket;

  /// The series of members or statements.
  final List<SequenceElementPiece> _elements;

  SequencePiece(this._elements, {Piece? leftBracket, Piece? rightBracket})
      : _leftBracket = leftBracket,
        _rightBracket = rightBracket;

  /// The closing delimiter, if any.
  final Piece? _rightBracket;

  @override
  List<State> get additionalStates => [if (_elements.isNotEmpty) State.split];

  @override
  void format(CodeWriter writer, State state) {
    writer.pushAllowNewlines(state == State.split);

    if (_leftBracket case var leftBracket?) {
      writer.format(leftBracket);
      writer.pushIndent(_elements.firstOrNull?._indent ?? 0);
      writer.splitIf(state == State.split, space: false);
    }

    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];

      // We can format an element separately if the element is on its own line.
      // This happens when the sequence is split and there is something before
      // and after the element, either brackets or other items.
      var separate = state == State.split &&
          (i > 0 || _leftBracket != null) &&
          (i < _elements.length - 1 || _rightBracket != null);

      writer.format(element, separate: separate);

      if (i < _elements.length - 1) {
        if (_leftBracket != null || i > 0) writer.popIndent();
        writer.pushIndent(_elements[i + 1]._indent);
        writer.newline(blank: element.blankAfter);
      }
    }

    if (_leftBracket != null || _elements.length > 1) writer.popIndent();

    if (_rightBracket case var rightBracket?) {
      writer.splitIf(state == State.split, space: false);
      writer.format(rightBracket);
    }

    writer.popAllowNewlines();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_leftBracket case var leftBracket?) callback(leftBracket);

    for (var element in _elements) {
      callback(element);
    }

    if (_rightBracket case var rightBracket?) callback(rightBracket);
  }

  @override
  String get debugName => 'Seq';
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
