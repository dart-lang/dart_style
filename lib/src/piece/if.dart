// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for an if statement or element.
///
/// We also use this for while statements, which are formatted exactly like an
/// if statement with no else clause.
class IfPiece extends Piece {
  /// Whether this is an if statement versus if collection element.
  final bool _isStatement;

  final List<_IfSection> _sections = [];

  IfPiece({required bool isStatement}) : _isStatement = isStatement;

  void add(Piece header, Piece statement, {required bool isBlock}) {
    _sections.add(_IfSection(header, statement, isBlock));
  }

  @override
  List<State> get additionalStates => [State.split];

  @override
  void applyConstraints(State state, Constrain constrain) {
    // In an if element, any spread collection's split state must follow the
    // surrounding if element's: we either split all the spreads or none of
    // them. And if any of the non-spread then or else branches split, then the
    // spreads do too.
    if (!_isStatement) {
      for (var section in _sections) {
        if (section.isBlock) {
          constrain(section.statement, state);
        }
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
  void format(CodeWriter writer, State state) {
    for (var i = 0; i < _sections.length; i++) {
      var section = _sections[i];

      // A split in the condition forces the branches to split.
      writer.pushAllowNewlines(state == State.split);
      writer.format(section.header);

      if (!section.isBlock) {
        writer.pushIndent(Indent.block);
        writer.splitIf(state == State.split);
      }

      // TODO(perf): Investigate whether it's worth using `separate:` here.
      writer.format(section.statement);

      // Reset the indentation for the subsequent `else` or `} else` line.
      if (!section.isBlock) writer.popIndent();

      if (i < _sections.length - 1) {
        writer.splitIf(state == State.split && !section.isBlock);
      }

      writer.popAllowNewlines();
    }
  }
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

  /// Whether the [statement] piece is from a block or a spread collection
  /// literal.
  final bool isBlock;

  _IfSection(this.header, this.statement, this.isBlock);
}
