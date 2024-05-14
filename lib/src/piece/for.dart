// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a for statement.
class ForPiece extends Piece {
  /// The `for` keyword.
  final Piece _forKeyword;

  /// The part inside `( ... )`, including the parentheses themselves, at the
  /// header of a for statement.
  final Piece _forParts;

  final Piece _body;

  /// Whether the contents of the parentheses in the `for (...)` should be
  /// expression indented or not.
  ///
  /// This is usually not necessary because the contents will either be a
  /// [ListPiece] which adds its own block indentation, or an [AssignPiece]
  /// which indents as necessary. But in the rare case the for-parts is a
  /// variable or pattern variable declaration with metadata that splits, we
  /// need to ensure that the metadata is indented, as in:
  ///
  ///     for (@LongAnnotation
  ///         @AnotherAnnotation
  ///         var element in list) { ... }
  final bool _indentForParts;

  /// Whether the body of the loop is a block versus some other statement. If
  /// the body isn't a block, then we allow a discretionary split after the
  /// loop parts, as in:
  ///
  ///     for (;;)
  ///       print("ok");
  final bool _hasBlockBody;

  ForPiece(this._forKeyword, this._forParts, this._body,
      {required bool indentForParts, required bool hasBlockBody})
      : _indentForParts = indentForParts,
        _hasBlockBody = hasBlockBody;

  /// If there is at least one else or else-if clause, then it always splits.
  @override
  List<State> get additionalStates => [if (!_hasBlockBody) State.split];

  @override
  void format(CodeWriter writer, State state) {
    var allowNewlines = _hasBlockBody || state == State.split;

    writer.format(_forKeyword, allowNewlines: allowNewlines);
    writer.space();

    if (_indentForParts) {
      writer.pushIndent(Indent.expression, canCollapse: true);
    }

    writer.format(_forParts, allowNewlines: allowNewlines);

    if (_indentForParts) writer.popIndent();

    if (_hasBlockBody) {
      writer.space();
    } else {
      writer.pushIndent(Indent.block);
      writer.splitIf(state == State.split);
    }

    writer.format(_body, allowNewlines: allowNewlines);
    if (!_hasBlockBody) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_forKeyword);
    callback(_forParts);
    callback(_body);
  }
}

/// A piece for the `<variable> in <expression>` part of a for-in loop.
///
/// Can be formatted two ways:
///
/// [State.unsplit] No split at all:
///
///     for (var x in y) ...
///
/// This state also allows splitting the sequence expression if it can be block
/// formatted:
///
///     for (var i in [
///       element1,
///       element2,
///       element3,
///     ];
///
/// [State.split] Split at the `in` operator and allow expression splitting on
/// either side. Allows:
///
///     for (var (longVariable &&
///             anotherVariable)
///         in longOperand +
///             anotherOperand) {
///       ...
///     }
class ForInPiece extends Piece {
  /// The variable or pattern initialized with each loop iteration.
  final Piece _variable;

  /// The `in` keyword followed by the sequence expression.
  final Piece _sequence;

  /// If `true` then the sequence expression supports being block-formatted,
  /// like:
  ///
  ///     for (var e in [
  ///       element1,
  ///       element2,
  ///     ]) {
  ///       // ...
  ///     }
  final bool _canBlockSplitSequence;

  ForInPiece(this._variable, this._sequence,
      {bool canBlockSplitSequence = false})
      : _canBlockSplitSequence = canBlockSplitSequence;

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    // When splitting at `in`, both operands may split or not and will be
    // indented if they do.
    if (state == State.split) writer.pushIndent(Indent.expression);

    writer.format(_variable, allowNewlines: state == State.split);

    writer.splitIf(state == State.split);

    // Always allow block-splitting the sequence if it supports it.
    writer.format(_sequence,
        allowNewlines: _canBlockSplitSequence || state == State.split);

    if (state == State.split) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_variable);
    callback(_sequence);
  }
}
