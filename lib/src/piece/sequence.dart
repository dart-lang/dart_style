// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
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
    writer.setAllowNewlines(state == State.split);

    if (_leftBracket case var leftBracket?) {
      writer.format(leftBracket);
      writer.splitIf(state == State.split,
          space: false, indent: _elements.firstOrNull?._indent ?? 0);
    }

    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];

      // If the sequence is split, then every element is on its own line and
      // can be formatted separately.
      writer.format(element, separate: state == State.split);

      if (i < _elements.length - 1) {
        writer.newline(
            blank: element.blankAfter, indent: _elements[i + 1]._indent);
      }
    }

    if (_rightBracket case var rightBracket?) {
      writer.splitIf(state == State.split, space: false, indent: Indent.none);
      writer.format(rightBracket);
    }
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
  final Piece _piece;

  /// The comments that should appear at the end of this element's line.
  final List<Piece> hangingComments = [];

  /// Whether there should be a blank line after this element.
  bool blankAfter = false;

  SequenceElementPiece(this._indent, this._piece);

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_piece);

    for (var comment in hangingComments) {
      writer.space();
      writer.format(comment);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_piece);
    for (var comment in hangingComments) {
      callback(comment);
    }
  }
}
