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

  /// Whether the body of the loop is a block versus some other statement. If
  /// the body isn't a block, then we allow a discretionary split after the
  /// loop parts, as in:
  ///
  /// ```
  /// for (;;)
  ///   print("ok");
  /// ```
  final bool _hasBlockBody;

  ForPiece(this._forKeyword, this._forParts, this._body,
      {required bool hasBlockBody})
      : _hasBlockBody = hasBlockBody;

  /// If there is at least one else or else-if clause, then it always splits.
  @override
  List<State> get additionalStates => [if (!_hasBlockBody) State.split];

  @override
  void format(CodeWriter writer, State state) {
    if (!_hasBlockBody && state == State.unsplit) {
      writer.setAllowNewlines(false);
    }

    writer.format(_forKeyword);
    writer.space();
    writer.format(_forParts);

    if (_hasBlockBody) {
      writer.space();
    } else {
      writer.splitIf(state == State.split, indent: Indent.block);
    }

    writer.format(_body);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_forKeyword);
    callback(_forParts);
    callback(_body);
  }

  @override
  String toString() => 'For';
}
