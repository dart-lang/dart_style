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

  /// Split before the `when` guard clause and after the `=>`.
  static const State _beforeWhenAndBody = State(2);

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
        if (_guard != null) ...[_beforeWhenAndBody],
      ];

  @override
  bool allowNewlineInChild(State state, Piece child) {
    return switch (state) {
      _ when child == _arrow => true,
      State.unsplit when child == _body && _canBlockSplitBody => true,
      _beforeBody when child == _pattern =>
        _guard == null || _patternIsLogicalOr,
      _beforeBody when child == _body => true,
      _beforeWhenAndBody => true,
      _ => false,
    };
  }

  @override
  void format(CodeWriter writer, State state) {
    // If there is a split guard, then indent the pattern past it.
    var indentPatternForGuard = !_canBlockSplitPattern &&
        !_patternIsLogicalOr &&
        state == _beforeWhenAndBody;

    if (indentPatternForGuard) writer.pushIndent(Indent.expression);

    writer.format(_pattern);

    if (indentPatternForGuard) writer.popIndent();

    if (_guard case var guard?) {
      writer.pushIndent(Indent.expression);
      writer.splitIf(state == _beforeWhenAndBody);
      writer.format(guard);
      writer.popIndent();
    }

    writer.space();
    writer.format(_arrow);

    if (state != State.unsplit) writer.pushIndent(Indent.block);

    writer.splitIf(state == _beforeBody || state == _beforeWhenAndBody);
    writer.format(_body);

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
