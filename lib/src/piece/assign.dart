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
/// "block-like" formatting of delimited expressions on the right, and for the
/// `in` clause in for-in loops.
///
/// These constructs can be formatted three ways:
///
/// [State.unsplit] No split at all:
///
///     var x = 123;
///
/// If the value is a delimited "block-like" expression, then we allow splitting
/// inside the value but not at the `=` with no additional indentation:
///
///     var list = [
///       element,
///     ];
///
/// [_atOperator] Split after the `=`:
///
///     var name =
///         longValueExpression;
class AssignPiece extends Piece {
  /// Split after the operator.
  ///
  /// This is more costly because it's generally better to split either in the
  /// value (if it's delimited) or in the target.
  static const State _atOperator = State(2, cost: 2);

  /// The left-hand side of the operation. Includes the operator unless it is
  /// `in`.
  final Piece target;

  /// The right-hand side of the operation.
  final Piece value;

  /// Whether a newline is allowed in the right-hand side without forcing a
  /// split at the assignment operator.
  final bool _allowInnerSplit;

  /// Whether there's an extra indent needed in the [value] piece when it
  /// splits, like:
  //
  //    if (obj
  //        case SomeLongTypeName
  //            longVariableName) {
  //      ;
  //    }
  final bool _indentInValue;

  AssignPiece(this.target, this.value,
      {bool allowInnerSplit = false, bool indentInValue = false})
      : _allowInnerSplit = allowInnerSplit,
        _indentInValue = indentInValue;

  // TODO(tall): The old formatter allows the first operand of a split
  // conditional expression to be on the same line as the `=`, as in:
  //
  //     var value = condition
  //         ? thenValue
  //         : elseValue;
  //
  // It's not clear if this behavior is deliberate or not. It does look OK,
  // though. We could do the same thing here. If we do, I think it's worth
  // considering allowing the same thing for infix expressions too:
  //
  //     var value = operand +
  //         operand +
  //         operand;
  //
  // For now, we do not implement this special case behavior. Once more of the
  // language is implemented in the new back end and we can run the formatter
  // on a large corpus of code, we can try it out and see if the special case
  // behavior is worth it.
  //
  // If we don't do that, consider at least not adding another level of
  // indentation for subsequent operands in an infix operator chain. So prefer:
  //
  //     var value =
  //         operand +
  //         operand +
  //         operand;
  //
  // Over:
  //
  //     var value =
  //         operand +
  //             operand +
  //             operand;

  @override
  List<State> get additionalStates => [_atOperator];

  @override
  void format(CodeWriter writer, State state) {
    // A split in either child piece forces splitting at assignment operator
    // unless specifically allowed.
    if (!_allowInnerSplit && state == State.unsplit) {
      writer.setAllowNewlines(false);
    }

    // Don't indent a split delimited expression.
    if (state != State.unsplit) writer.pushIndent(Indent.expression);

    writer.format(target);
    writer.splitIf(state == _atOperator);

    // We need extra indentation when there's no inner splitting of the value.
    if (!_allowInnerSplit && _indentInValue) {
      writer.pushIndent(Indent.expression);
    }

    writer.format(value);

    if (!_allowInnerSplit && _indentInValue) {
      writer.popIndent();
    }

    if (state != State.unsplit) writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(target);
    callback(value);
  }
}
