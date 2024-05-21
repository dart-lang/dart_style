// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// Piece for the contents inside the parentheses for an if-case statement or
/// element: the expression, `case`, pattern, and `when` clause, if any.
///
/// They can split a few different ways:
///
/// [State.unsplit] All on one line:
///
///     if (obj case pattern when cond) ...
///
/// The pattern may also be block-formatted in this state:
///
///     if (obj case [
///       subpattern,
///     ] when cond) ...
///
/// [_beforeWhen] Split before the guard clause but not the pattern:
///
///     if (obj case pattern
///         when cond) ...
///
/// [_beforeCase] Split before the `case` clause but not the guard:
///
///     if (obj
///         case pattern when cond) ...
///
/// [_beforeCaseAndWhen] Split before both `case` and `when`:
///
///     if (obj
///         case pattern
///         when cond) ...
class IfCasePiece extends Piece {
  /// Split before the `when` guard clause.
  static const State _beforeWhen = State(1);

  /// Split before the `case` pattern clause.
  static const State _beforeCase = State(2);

  /// Split before the `case` pattern clause and the `when` guard clause.
  static const State _beforeCaseAndWhen = State(3);

  /// The value expression being matched.
  final Piece _value;

  /// The pattern the value is matched against along with the leading `case`.
  final Piece _pattern;

  /// If there is a `when` clause, that clause.
  final Piece? _guard;

  /// Whether the pattern can be block formatted.
  final bool _canBlockSplitPattern;

  IfCasePiece(this._value, this._pattern, this._guard,
      {required bool canBlockSplitPattern})
      : _canBlockSplitPattern = canBlockSplitPattern;

  @override
  List<State> get additionalStates => [
        if (_guard != null) _beforeWhen,
        _beforeCase,
        if (_guard != null) _beforeCaseAndWhen
      ];

  @override
  bool allowNewlineInChild(State state, Piece child) {
    return switch (state) {
      // When not splitting before `case` or `when`, we only allow newlines
      // in block-formatted patterns.
      State.unsplit when child == _pattern => _canBlockSplitPattern,

      // Allow newlines only in the guard if we split before `when`.
      _beforeWhen when child == _guard => true,

      // Only allow the guard on the same line as the pattern if it doesn't
      // split.
      _beforeCase when child != _guard => true,
      _beforeCaseAndWhen => true,
      _ => false,
    };
  }

  @override
  void format(CodeWriter writer, State state) {
    if (state != State.unsplit) writer.pushIndent(Indent.expression);

    writer.format(_value);

    // The case clause and pattern.
    writer.splitIf(state == _beforeCase || state == _beforeCaseAndWhen);

    if (!_canBlockSplitPattern) {
      writer.pushIndent(Indent.expression, canCollapse: true);
    }

    writer.format(_pattern);

    if (!_canBlockSplitPattern) writer.popIndent();

    // The guard clause.
    if (_guard case var guard?) {
      writer.splitIf(state == _beforeWhen || state == _beforeCaseAndWhen);
      writer.format(guard);
    }

    if (state != State.unsplit) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_value);
    callback(_pattern);
    if (_guard case var guard?) callback(guard);
  }
}
