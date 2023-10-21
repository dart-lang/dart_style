// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for an if statement.
///
/// We also use this for while statements, which are formatted exactly like an
/// if statement with no else clause.
class IfPiece extends Piece {
  final List<_IfSection> _sections = [];

  /// Whether the if is a simple if with only a single unbraced then statement
  /// and no else clause, like:
  ///
  /// ```
  /// if (condition) print("ok");
  /// ```
  ///
  /// Unlike other if statements, these allow a discretionary split after the
  /// condition.
  bool get _isUnbracedIfThen =>
      _sections.length == 1 && !_sections.single.isBlock;

  void add(Piece header, Piece statement, {required bool isBlock}) {
    _sections.add(_IfSection(header, statement, isBlock));
  }

  /// If there is at least one else or else-if clause, then it always splits.
  @override
  List<State> get additionalStates => [if (_isUnbracedIfThen) State.split];

  @override
  void format(CodeWriter writer, State state) {
    if (_isUnbracedIfThen) {
      // A split in the condition or statement forces moving the entire
      // statement to the next line.
      writer.setAllowNewlines(state != State.unsplit);

      var section = _sections.single;
      writer.format(section.header);
      writer.splitIf(state == State.split, indent: Indent.block);
      writer.format(section.statement);
      return;
    }

    for (var i = 0; i < _sections.length; i++) {
      var section = _sections[i];

      writer.format(section.header);

      // If the statement is a block, then keep the `{` on the same line as the
      // header part.
      if (section.isBlock) {
        writer.space();
      } else {
        writer.newline(indent: Indent.block);
      }

      writer.format(section.statement);

      // Reset the indentation for the subsequent `else` or `} else` line.
      if (i < _sections.length - 1) {
        writer.splitIf(!section.isBlock, indent: Indent.none);
      }
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    for (var section in _sections) {
      callback(section.header);
      callback(section.statement);
    }
  }

  @override
  String toString() => 'If';
}

/// A single section in a chain of if-elses.
///
/// For the first then branch, the [header] is the `if (condition)` part and
/// the statement is the then branch. For all `else if` branches, the [header]
/// is the `else if (condition)` and the statement is the subsequent then
/// branch. For the final `else` branch, if there is one, the [header] is just
/// `else` and the statement is the else branch.
class _IfSection {
  final Piece header;
  final Piece statement;

  /// Whether the [statement] piece is from a block.
  final bool isBlock;

  _IfSection(this.header, this.statement, this.isBlock);
}
