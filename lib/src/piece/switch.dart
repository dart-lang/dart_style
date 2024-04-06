// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// Piece for a switch expression.
///
/// A switch expression can format in a few ways:
///
/// [State.unsplit] The value and cases all fit on one line:
///
///     switch (foo) { _ => 1 };
///
/// [_splitCases] The cases split, but the value does not:
///
///     switch (foo) {
///       _ => 1,
///     }
///
/// [_blockSplitValueSplitCases] The value block splits and the cases split:
///
///     switch ([
///       foo,
///     ]) {
///       _ => 1,
///     }
///
/// [State.split] The value and cases split, but the value doesn't block split.
///
///     switch (foo +
///         bar) {
///       _ => 1,
///     }
///
/// We make a distinction between the last two styles because the former is
/// considered [Shape.block], but the latter is not, thus:
///
///     // Allowed:
///     variable = switch ([
///       foo,
///     ]) {
///       _ => 1,
///     }
///
///     // Disallowed:
///     variable = switch (foo +
///         bar) {
///       _ => 1,
///     }
///
/// If the value splits, the cases always split.
class SwitchExpressionPiece extends Piece {
  /// State when the cases split but the value does not.
  static const State _splitCases = State(1, cost: 0);

  /// State when the value block splits and the cases split.
  static const State _blockSplitValueSplitCases = State(2, cost: 0);

  /// The `switch (` before the value.
  final Piece _header;

  /// The value expression.
  final Piece _value;

  /// The `) ` between the value and cases.
  final Piece _separator;

  /// The `{ ... }` cases.
  final Piece _cases;

  SwitchExpressionPiece(
      this._header, this._value, this._separator, this._cases);

  @override
  List<State> get additionalStates =>
      const [_splitCases, _blockSplitValueSplitCases, State.split];

  @override
  Shape shapeForState(State state) {
    return switch (state) {
      _splitCases || _blockSplitValueSplitCases => Shape.block,
      _ => Shape.other,
    };
  }

  @override
  void applyShapeConstraints(State state, ConstrainShape constrain) {
    if (state != State.unsplit) constrain(_cases, Shape.block);
    if (state == _blockSplitValueSplitCases) constrain(_value, Shape.block);
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

      case _blockSplitValueSplitCases:
        writer.format(_header);
        writer.format(_value);
        writer.format(_separator);
        writer.format(_cases);

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

/// Piece for a case pattern, guard, and body in a switch expression.
class CaseExpressionPiece extends Piece {
  /// Block split the case body expression.
  static const State _blockSplitBody = State(1, cost: 0);

  /// Split after the `=>` before the body.
  static const State _beforeBody = State(2);

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

  CaseExpressionPiece(this._pattern, this._guard, this._arrow, this._body,
      {required bool canBlockSplitPattern, required bool patternIsLogicalOr})
      : _canBlockSplitPattern = canBlockSplitPattern,
        _patternIsLogicalOr = patternIsLogicalOr;

  @override
  List<State> get additionalStates => [
        _blockSplitBody,
        _beforeBody,
        if (_guard != null) ...[_beforeWhenAndBody],
      ];

  @override
  void applyShapeConstraints(State state, ConstrainShape constrain) {
    switch (state) {
      case _blockSplitBody:
        constrain(_body, Shape.block);
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        _writePattern(writer);
        _writeGuard(writer);
        _writeBody(writer, allowNewlineInBody: false);

      case _blockSplitBody:
        _writePattern(writer);
        _writeGuard(writer);
        _writeBody(writer, allowNewlineInBody: true);

      case _beforeBody:
        _writePattern(writer,
            allowNewlineInPattern: _guard == null || _patternIsLogicalOr);
        _writeGuard(writer);
        _writeBody(writer,
            indent: true, splitBeforeBody: true, allowNewlineInBody: true);

      case _beforeWhenAndBody:
        _writePattern(writer,
            allowNewlineInPattern: true, indentForGuard: true);
        _writeGuard(writer, splitGuard: true);
        _writeBody(writer,
            indent: true, splitBeforeBody: true, allowNewlineInBody: true);
    }
  }

  void _writePattern(CodeWriter writer,
      {bool allowNewlineInPattern = false, bool indentForGuard = false}) {
    // If there is a split guard, then indent the pattern past it.
    var indentPatternForGuard =
        indentForGuard && !_canBlockSplitPattern && !_patternIsLogicalOr;

    if (indentPatternForGuard) writer.pushIndent(Indent.expression);

    writer.format(_pattern, allowNewlines: allowNewlineInPattern);

    if (indentPatternForGuard) writer.popIndent();
  }

  void _writeGuard(CodeWriter writer, {bool splitGuard = false}) {
    if (_guard case var guard?) {
      writer.pushIndent(Indent.expression);
      writer.splitIf(splitGuard);
      writer.format(guard, allowNewlines: splitGuard);
      writer.popIndent();
    }
  }

  void _writeBody(CodeWriter writer,
      {bool splitBeforeBody = false,
      bool allowNewlineInBody = false,
      bool indent = false}) {
    writer.space();
    writer.format(_arrow);

    if (indent) writer.pushIndent(Indent.block);

    writer.splitIf(splitBeforeBody);
    writer.format(_body, allowNewlines: allowNewlineInBody);

    if (indent) writer.popIndent();
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
    var allowNewlines = _guard == null || state == State.split;

    // If there is a guard, then indent the pattern past it.
    if (_guard != null) writer.pushIndent(Indent.expression);
    writer.format(_pattern, allowNewlines: allowNewlines);
    if (_guard != null) writer.popIndent();

    if (_guard case var guard?) {
      writer.pushIndent(Indent.expression);
      writer.splitIf(state == State.split);
      writer.format(guard, allowNewlines: allowNewlines);
      writer.popIndent();
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_pattern);
    if (_guard case var guard?) callback(guard);
  }
}
