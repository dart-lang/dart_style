// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for any construct where `=` is followed by an expression: variable
/// initializer, assignment, constructor initializer, etc.
///
/// This piece is also used for map entries and named arguments where `:` is
/// followed by an expression or element because those also want to support the
/// "block-like" formatting of delimited expressions on the right.
///
/// These constructs can be formatted three ways:
///
/// [State.unsplit] No split at all:
///
/// ```
/// var x = 123;
/// ```
///
/// [_insideValue] If the value is a delimited "block-like" expression,
/// then we can split inside the block but not at the `=` with no additional
/// indentation:
///
/// ```
/// var list = [
///   element,
/// ];
/// ```
///
/// [State.split] Split after the `=`:
///
/// ```
/// var name =
///     longValueExpression;
/// ```
class AssignPiece extends Piece {
  /// Split inside the value but not at the `=`.
  ///
  /// This is only allowed when the value is a delimited expression.
  static const State _insideValue = State(1);

  /// Split after the `=` and allow splitting inside the value.
  ///
  /// This is more costly because, when it's possible to split inside a
  /// delimited value, we want to prefer that.
  static const State _atEquals = State(2, cost: 2);

  /// The left-hand side of the `=` and the `=` itself.
  final Piece target;

  /// The right-hand side of the `=`.
  final Piece value;

  final bool _isValueDelimited;

  AssignPiece(this.target, this.value, {required bool isValueDelimited})
      : _isValueDelimited = isValueDelimited;

  // TODO(tall): The old formatter allows the first operand of a split
  // conditional expression to be on the same line as the `=`, as in:
  //
  // ```
  // var value = condition
  //     ? thenValue
  //     : elseValue;
  // ```
  //
  // It's not clear if this behavior is deliberate or not. It does look OK,
  // though. We could do the same thing here. If we do, I think it's worth
  // considering allowing the same thing for infix expressions too:
  //
  // ```
  // var value = operand +
  //    operand +
  //    operand;
  // ```
  //
  // For now, we not implement this special case behavior. Once more of the
  // language is implemented in the new back end and we can run the formatter
  // on a large corpus of code, we can try it out and see if the special case
  // behavior is worth it.

  @override
  List<State> get additionalStates =>
      [if (_isValueDelimited) _insideValue, _atEquals];

  @override
  void format(CodeWriter writer, State state) {
    // A split in either child piece forces splitting after the "=" unless it's
    // a delimited expression.
    if (state == State.unsplit) writer.setAllowNewlines(false);

    // Don't indent a split delimited expression.
    if (state != _insideValue) writer.setIndent(Indent.expression);

    writer.format(target);
    writer.splitIf(state == _atEquals);
    writer.format(value);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(target);
    callback(value);
  }

  @override
  String toString() => 'Assign';
}
