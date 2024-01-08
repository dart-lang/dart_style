// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

// TODO(tall): This will probably become more elaborate when full method chains
// with interesting argument lists are supported. Right now, it's just the
// basics needed for instance creation expressions which may have method-like
// `.` in them.

/// A dotted series of property access or method calls, like:
///
///     target.getter.method().another.method();
///
/// This piece handles splitting before the `.`.
class ChainPiece extends Piece {
  /// The series of operations.
  ///
  /// The first piece in this is the target, and the rest are operations.
  final List<Piece> _operations;

  ChainPiece(this._operations);

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    if (state == State.unsplit) {
      writer.setAllowNewlines(false);
    } else {
      writer.setIndent(Indent.expression);
    }

    for (var i = 0; i < _operations.length; i++) {
      if (i > 0) writer.splitIf(state == State.split, space: false);
      writer.format(_operations[i]);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _operations.forEach(callback);
  }
}
