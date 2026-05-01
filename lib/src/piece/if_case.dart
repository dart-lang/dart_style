// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
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
final class IfCasePiece extends Piece {
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

  factory IfCasePiece(
    Piece value,
    Piece pattern,
    Piece? guard, {
    required bool canBlockSplitPattern,
    required bool canBlockFormatPatternWithGuard,
  }) {
    if (canBlockFormatPatternWithGuard) {
      return _IfCasePieceBlockFormatWithGuard(
        value,
        pattern,
        guard,
        canBlockSplitPattern: canBlockSplitPattern,
      );
    } else {
      return IfCasePiece._(
        value,
        pattern,
        guard,
        canBlockSplitPattern: canBlockSplitPattern,
      );
    }
  }

  IfCasePiece._(
    this._value,
    this._pattern,
    this._guard, {
    required bool canBlockSplitPattern,
  }) : _canBlockSplitPattern = canBlockSplitPattern;

  @override
  List<State> get additionalStates => [
    if (_guard != null) _beforeWhen,
    _beforeCase,
    if (_guard != null) _beforeCaseAndWhen,
  ];

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    return switch (state) {
      // When not splitting before `case` or `when`, we only allow splitting a
      // block-formatted pattern if there is no guard.
      State.unsplit
          when child == _pattern && _canBlockSplitPattern && _guard == null =>
        Shape.inlineOrBlock,

      // Allow newlines only in the guard if we split before `when`.
      _beforeWhen when child == _guard => Shape.all,

      // If there's no guard, then we can split anywhere in the pattern when
      // splitting after `case`.
      _beforeCase when child == _pattern && _guard == null => Shape.all,

      // If there is a guard, then the entire pattern and guard must fit on
      // one line, but the value expression can split.
      _beforeCase when child == _value => Shape.all,

      // Once we split at both `case` and `when`, then splits are allowed
      // everywhere.
      _beforeCaseAndWhen => Shape.all,

      _ => Shape.onlyInline,
    };
  }

  @override
  void format(CodeWriter writer, State state) {
    if (state != State.unsplit) writer.pushIndent(Indent.expression);

    writer.format(_value);

    // The case clause and pattern.
    writer.splitIf(state == _beforeCase || state == _beforeCaseAndWhen);

    if (!_canBlockSplitPattern) {
      writer.pushCollapsibleIndent();
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

/// An [IfCasePiece] for language versions older than 3.13.
///
/// In 3.13, we made if-case formatting stricter about block-formatting patterns
/// in the presence of a guard. Before 3.13, the formatter would allow output
/// like:
///
///     if (expression case [
///       constant,
///       another
///     ] when guardExpression) {
///      ...
///     }
///
/// Allowing the `when` clause hanging off the block-formatted pattern can make
/// it hard to see. In 3.13, we force a split before the `when` if the pattern
/// splits:
///
///     if (expression
///         case [
///           constant,
///           another
///         ]
///         when guardExpression) {
///      ...
///     }
///
/// A deliberate consequence of this change is that the formatter will prefer
/// splitting the guard and keeping the pattern on one line instead of block
/// splitting the pattern:
///
///     // Before:
///     if (expression case SomeClass(
///       property: var x,
///     ) when guardClause(x)) {
///
///     // After:
///     if (expression case SomeClass(property: var x)
///         when guardClause(x)) {
///
/// The change is language-versioned and this class implements the previous
/// behavior.
final class _IfCasePieceBlockFormatWithGuard extends IfCasePiece {
  _IfCasePieceBlockFormatWithGuard(
    super.value,
    super.pattern,
    super.guard, {
    required super.canBlockSplitPattern,
  }) : super._();

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    return switch (state) {
      // When not splitting before `case` or `when`, we only allow newlines
      // in block-formatted patterns.
      State.unsplit when child == _pattern => Shape.anyIf(
        _canBlockSplitPattern,
      ),

      // Allow newlines only in the guard if we split before `when`.
      IfCasePiece._beforeWhen when child == _guard => Shape.all,

      // Only allow the guard on the same line as the pattern if it doesn't
      // split.
      IfCasePiece._beforeCase when child != _guard => Shape.all,
      IfCasePiece._beforeCaseAndWhen => Shape.all,
      _ => Shape.onlyInline,
    };
  }
}
