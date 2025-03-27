// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import 'piece.dart';

/// A piece for a prefix expression.
/// Prevents the inner construct's indentation from being merged with the
/// surrounding context. Ensures we get:
///
///     variable =
///         throw 'long adjacent string'
///            'more string';
///
/// And not:
///
///     variable =
///         throw 'long adjacent string'
///         'more string';
final class PrefixPiece extends Piece {
  final Piece _content;

  PrefixPiece(this._content);

  @override
  void format(CodeWriter writer, State state) {
    writer.pushIndent(Indent.grouping);
    writer.format(_content);
    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_content);
  }
}
