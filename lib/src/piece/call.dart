// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

// TODO: Docs.
class CallPiece extends Piece {
  static const State _splitArguments = State(1, cost: 0);

  // split both
  static const State _splitTypeArguments = State(2, cost: 0);

  static const State _splitFunction = State(3, cost: 0);

  final Piece _function;
  final Piece? _typeArguments;
  final Piece _arguments;

  CallPiece(this._function, this._typeArguments, this._arguments);

  @override
  List<State> get additionalStates => [
        _splitArguments,
        if (_typeArguments != null) _splitTypeArguments,
        _splitFunction
      ];

  @override
  void applyConstraints(State state, Constrain constrain) {
    switch (state) {
      //   case _splitArguments:
      //     constrain(_arguments, State.split);

      case _splitTypeArguments:
      // constrain(_typeArguments!, State.split);
      // constrain(_arguments, State.split);

      //   case State.split:
      //     if (_typeArguments case var typeArguments?) {
      //       constrain(typeArguments, State.split);
      //     }
      //     constrain(_arguments, State.split);
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_function, allowNewlines: state == _splitFunction);

    if (_typeArguments case var typeArguments?) {
      writer.format(typeArguments, allowNewlines: state == _splitTypeArguments);
    }

    writer.format(_arguments, allowNewlines: state != State.unsplit);

    if (state == _splitArguments || state == _splitTypeArguments) {
      writer.setSplitType(SplitType.block);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_function);
    if (_typeArguments case var typeArguments?) callback(typeArguments);
    callback(_arguments);
  }
}

// TODO: Docs.
class CollectionPiece extends Piece {
  final Piece? _constKeyword;
  final Piece? _typeArguments;
  final Piece _elements;

  CollectionPiece(this._constKeyword, this._typeArguments, this._elements);

  @override
  List<State> get additionalStates => const [State.split];

  // TODO: explain just passing through.
  @override
  int stateCost(State state) => 0;

  @override
  void applyConstraints(State state, Constrain constrain) {
    if (state == State.split) constrain(_elements, State.split);
  }

  @override
  void format(CodeWriter writer, State state) {
    if (_constKeyword case var constKeyword?) writer.format(constKeyword);
    if (_typeArguments case var typeArguments?) writer.format(typeArguments);

    var elementSplit = writer.format(_elements);
    if (elementSplit == SplitType.block) writer.setSplitType(SplitType.block);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_constKeyword case var constKeyword?) callback(constKeyword);
    if (_typeArguments case var typeArguments?) callback(typeArguments);
    callback(_elements);
  }
}

// TODO: Docs.
// ways it can format:
//
// all inline:
//
//     switch (foo) { _ => 1 };
//
// block split body:
//
//     switch (foo) {
//       _ => 1,
//     }
//
// block split body and block split value:
//
//     switch ([
//       foo,
//     ]) {
//       _ => 1,
//     }
//
// block split body and expr split value:
//
//     switch (foo +
//         bar) {
//       _ => 1,
//     }
class SwitchExpressionPiece extends Piece {
  static const State _splitCases = State(1);

  static const State _blockSplitValueSplitCases = State(2);

  final Piece _header;
  final Piece _value;
  final Piece _separator;
  final Piece _cases;

  SwitchExpressionPiece(
      this._header, this._value, this._separator, this._cases);

  @override
  List<State> get additionalStates =>
      const [_splitCases, _blockSplitValueSplitCases, State.split];

  // TODO: Better doc.
  // Always zero because costs from value and cases are sufficient.
  @override
  int stateCost(State state) => 0;

  @override
  void applyConstraints(State state, Constrain constrain) {
    if (state != State.unsplit) constrain(_cases, State.split);
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        writer.format(_header, allowNewlines: false);
        writer.format(_value, allowNewlines: false);
        writer.format(_separator, allowNewlines: false);
        writer.format(_cases, allowNewlines: false);

      case _splitCases:
        writer.format(_header);
        writer.format(_value, allowNewlines: false);
        writer.format(_separator);
        writer.format(_cases);

        writer.setSplitType(SplitType.block);

      case _blockSplitValueSplitCases:
        writer.format(_header);
        var valueSplit = writer.format(_value);
        writer.format(_separator);
        writer.format(_cases);

        if (valueSplit != SplitType.block) writer.invalidate(_value);
        writer.setSplitType(SplitType.block);

      case State.split:
        writer.format(_header);
        writer.format(_value);
        writer.format(_separator);
        writer.format(_cases);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_header);
    callback(_value);
    callback(_separator);
    callback(_cases);
  }
}

class ParenthesizedPiece extends Piece {
  final Piece _leftParenthesis;
  final Piece _piece;
  final Piece _rightParenthesis;

  ParenthesizedPiece(
      this._leftParenthesis, this._piece, this._rightParenthesis);

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_leftParenthesis);
    var splitType = writer.format(_piece);
    writer.format(_rightParenthesis);

    writer.setSplitType(splitType);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_leftParenthesis);
    callback(_piece);
    callback(_rightParenthesis);
  }
}

// TODO: Is this worth keeping? Maybe get rid of this and parenthesized and
// instead have AdjacentPiece be able to plumb a SplitStyle through if there
// is only a single non-SplitStyle.none result?
class CommaPiece extends Piece {
  final Piece _piece;
  final Piece _comma;

  CommaPiece(this._piece, this._comma);

  @override
  void format(CodeWriter writer, State state) {
    var splitType = writer.format(_piece);
    writer.format(_comma);

    writer.setSplitType(splitType);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_piece);
    callback(_comma);
  }
}
