// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// Piece for a series of adjacent strings, like:
///
///     var message =
///         'This is a long message '
///         'split into multiple strings';
class AdjacentStringsPiece extends Piece {
  final List<Piece> _strings;

  /// Whether strings after the first should be indented.
  final bool _indent;

  AdjacentStringsPiece(this._strings, {bool indent = true}) : _indent = indent;

  @override
  void format(CodeWriter writer, State state) {
    if (_indent) writer.pushIndent(Indent.expression);

    for (var i = 0; i < _strings.length; i++) {
      if (i > 0) writer.newline();
      writer.format(_strings[i]);
    }

    if (_indent) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _strings.forEach(callback);
  }
}
