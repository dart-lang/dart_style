// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// Piece for a case pattern, guard, and body in a switch expression.
class CaseExpressionPiece extends Piece {
  /// Split after the `=>` before the body.
  static const State _beforeBody = State(1);

  /// Split before the `when` guard clause.
  static const State _beforeWhen = State(2);

  /// Split before the `when` guard clause and after the `=>`.
  static const State _beforeWhenAndBody = State(3);

  /// The pattern the value is matched against along with the leading `case`.
  final Piece _pattern;

  /// If there is a `when` clause, that clause.
  final Piece? _guard;

  /// The `=>` token separating the pattern and body.
  final Piece _arrow;

  /// The case body expression.
  final Piece _body;

  /// Whether the pattern can be block formatted.
  final bool _canBlockSplitPattern;

  /// Whether the outermost pattern is a logical-or pattern.
  ///
  /// We format these specially to make them look like parallel cases:
  ///
  ///     switch (obj) {
  ///       firstPattern ||
  ///       secondPattern ||
  ///       thirdPattern =>
  ///         body;
  ///     }
  final bool _patternIsLogicalOr;

  /// Whether the body expression can be block formatted.
  final bool _canBlockSplitBody;

  CaseExpressionPiece(this._pattern, this._guard, this._arrow, this._body,
      {required bool canBlockSplitPattern,
      required bool patternIsLogicalOr,
      required bool canBlockSplitBody})
      : _canBlockSplitPattern = canBlockSplitPattern,
        _patternIsLogicalOr = patternIsLogicalOr,
        _canBlockSplitBody = canBlockSplitBody;

  @override
  List<State> get additionalStates => [
        _beforeBody,
        if (_guard != null) ...[_beforeWhen, _beforeWhenAndBody],
      ];

  @override
  void format(CodeWriter writer, State state) {
    var allowNewlineInPattern = false;
    var allowNewlineInGuard = false;
    var allowNewlineInBody = false;

    switch (state) {
      case State.unsplit:
        allowNewlineInBody = _canBlockSplitBody;
        break;

      case _beforeBody:
        allowNewlineInPattern = _guard == null || _patternIsLogicalOr;
        allowNewlineInBody = true;

      case _beforeWhen:
        // Allow newlines only in the pattern if we split before `when`.
        allowNewlineInPattern = true;

      case _beforeWhenAndBody:
        allowNewlineInPattern = true;
        allowNewlineInGuard = true;
        allowNewlineInBody = true;
    }

    // If there is a split guard, then indent the pattern past it.
    var indentPatternForGuard = !_canBlockSplitPattern &&
        !_patternIsLogicalOr &&
        (state == _beforeWhen || state == _beforeWhenAndBody);

    if (indentPatternForGuard) writer.pushIndent(Indent.expression);

    writer.pushAllowNewlines(allowNewlineInPattern);
    writer.format(_pattern);
    writer.popAllowNewlines();

    if (indentPatternForGuard) writer.popIndent();

    if (_guard case var guard?) {
      writer.pushIndent(Indent.expression);
      writer.pushAllowNewlines(allowNewlineInGuard);
      writer.splitIf(state == _beforeWhen || state == _beforeWhenAndBody);
      writer.format(guard);
      writer.popAllowNewlines();
      writer.popIndent();
    }

    writer.space();
    writer.format(_arrow);

    if (state != State.unsplit) writer.pushIndent(Indent.block);

    writer.splitIf(state == _beforeBody || state == _beforeWhenAndBody);
    writer.pushAllowNewlines(allowNewlineInBody);
    writer.format(_body);
    writer.popAllowNewlines();

    if (state != State.unsplit) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_pattern);
    if (_guard case var guard?) callback(guard);
    callback(_arrow);
    callback(_body);
  }
}

/// Piece for a case pattern and guard in a switch statement.
///
/// Unlike [CaseExpressionPiece], this doesn't include the case body, because
/// in a statement, the body is formatted as separate elements in the
/// surrounding sequence.
///
/// This just handles splitting between the pattern and guard.
///
/// [State.unsplit] No split before the guard:
///
///     case pattern when condition:
///
/// [State.split] Split before the `when`:
///
///     case someVeryLongPattern ||
///             anotherSubpattern
///         when longGuardCondition &&
///             anotherOperand:
class CaseStatementPiece extends Piece {
  /// The pattern the value is matched against along with the leading `case`.
  final Piece _pattern;

  /// If there is a `when` clause, that clause.
  final Piece? _guard;

  CaseStatementPiece(this._pattern, this._guard);

  @override
  List<State> get additionalStates => [
        if (_guard != null) State.split,
      ];

  @override
  void format(CodeWriter writer, State state) {
    writer.pushAllowNewlines(_guard == null || state == State.split);

    // If there is a guard, then indent the pattern past it.
    if (_guard != null) writer.pushIndent(Indent.expression);
    writer.format(_pattern);
    if (_guard != null) writer.popIndent();

    if (_guard case var guard?) {
      writer.pushIndent(Indent.expression);
      writer.splitIf(state == State.split);
      writer.format(guard);
      writer.popIndent();
    }

    writer.popAllowNewlines();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_pattern);
    if (_guard case var guard?) callback(guard);
  }
}
