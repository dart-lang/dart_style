// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/chain.dart';
import '../piece/piece.dart';
import 'piece_factory.dart';

/// Creates [Chain] pieces from method calls and property accesses, along with
/// postfix operations (`!`, index operators, and function invocation
/// expressions) that follow them.
///
/// In the AST for method calls, selectors are nested bottom up such that this
/// expression:
///
///     obj.a(1)[2].c(3)
///
/// Is structured like:
///
///           .c()
///           /  \
///          []   3
///         /  \
///       .a()  2
///       /  \
///     obj   1
///
/// This means visiting the AST from top down visits the selectors from right
/// to left. It's easier to format if we organize them as a linear series of
/// selectors from left to right. Further, we want to organize it into a
/// two-tier hierarchy. We have an outer list of method calls and property
/// accesses. Then each of those may have one or more postfix selectors
/// attached: indexers, null-assertions, or invocations. This mirrors how they
/// are formatted.
///
/// This lets us create a single [ChainPiece] for the entire series of dotted
/// operations, so that we can control splitting them or not as a unit.
class ChainBuilder {
  final PieceFactory _visitor;

  /// The left-most target of the chain.
  late Piece _target;

  /// Whether the target expression may contain newlines when the chain is not
  /// fully split. (It may always contain newlines when the chain splits.)
  ///
  /// This is true for most expressions but false for delimited ones to avoid
  /// ugly formatting like:
  ///
  ///     function(
  ///       argument,
  ///     )
  ///         .method();
  late final bool _allowSplitInTarget;

  /// The dotted property accesses and method calls following the target.
  final List<ChainCall> _calls = [];

  ChainBuilder(this._visitor, Expression expression) {
    _unwrapCall(expression);
  }

  Piece build() {
    // If there are no calls, there's no chain.
    if (_calls.isEmpty) return _target;

    // Count the number of contiguous properties at the beginning of the chain.
    var leadingProperties = 0;
    while (leadingProperties < _calls.length &&
        _calls[leadingProperties].type == CallType.property) {
      leadingProperties++;
    }

    // See if there is a call that we can block format. It can either be the
    // very last call, if non-empty:
    //
    //     target.property.method().last(
    //       argument,
    //     );
    //
    // Or the second-to-last if the last call can't split:
    //
    //     target.property.method().penultimate(
    //       argument,
    //     ).toList();
    var blockCallIndex = switch (_calls) {
      [..., ChainCall(canSplit: true)] => _calls.length - 1,
      [..., ChainCall(canSplit: true), ChainCall(canSplit: false)] =>
        _calls.length - 2,
      _ => -1,
    };

    return ChainPiece(_target, _calls, leadingProperties, blockCallIndex,
        allowSplitInTarget: _allowSplitInTarget);
  }

  /// Given [expression], which is the outermost expression for some call chain,
  /// recursively traverses the selectors to fill in the list of [_calls].
  ///
  /// Initializes [_target] with the innermost subexpression that isn't a part
  /// of the call chain. For example, given:
  ///
  ///     foo.bar()!.baz[0][1].bang()
  ///
  /// This returns `foo` and fills [_calls] with:
  ///
  ///     .bar()!
  ///     .baz[0][1]
  ///     .bang()
  void _unwrapCall(Expression expression) {
    switch (expression) {
      case Expression(looksLikeStaticCall: true):
        // Don't include things that look like static method or constructor
        // calls in the call chain because that tends to split up named
        // constructors from their class.
        _visitTarget(expression);

      // Selectors.
      case MethodInvocation(:var target?):
        _unwrapCall(target);

        var callPiece = _visitor.buildPiece((b) {
          b.token(expression.operator);
          b.visit(expression.methodName);
          b.visit(expression.typeArguments);
          b.visit(expression.argumentList);
        });

        var canSplit = expression.argumentList.arguments
            .canSplit(expression.argumentList.rightParenthesis);
        _calls.add(ChainCall(callPiece,
            canSplit ? CallType.splittableCall : CallType.unsplittableCall));

      case PropertyAccess(:var target?):
        _unwrapCall(target);

        var piece = _visitor.buildPiece((b) {
          b.token(expression.operator);
          b.visit(expression.propertyName);
        });

        _calls.add(ChainCall(piece, CallType.property));

      case PrefixedIdentifier(:var prefix):
        _unwrapCall(prefix);

        var piece = _visitor.buildPiece((b) {
          b.token(expression.period);
          b.visit(expression.identifier);
        });

        _calls.add(ChainCall(piece, CallType.property));

      // Postfix expressions.
      case FunctionExpressionInvocation():
        _unwrapPostfix(expression.function, (target) {
          return _visitor.buildPiece((b) {
            b.add(target);
            b.visit(expression.typeArguments);
            b.visit(expression.argumentList);
          });
        });

      case IndexExpression():
        _unwrapPostfix(expression.target!, (target) {
          return _visitor.createIndexExpression(target, expression);
        });

      case PostfixExpression() when expression.operator.type == TokenType.BANG:
        _unwrapPostfix(expression.operand, (target) {
          return _visitor.buildPiece((b) {
            b.add(target);
            b.token(expression.operator);
          });
        });

      default:
        // Otherwise, it isn't a selector so we've reached the target.
        _visitTarget(expression);
    }
  }

  /// Creates and stores the resulting Piece for [target] as well as whether it
  /// allows being split.
  void _visitTarget(Expression target) {
    _allowSplitInTarget = target.canBlockSplit;
    _target = _visitor.nodePiece(target);
  }

  void _unwrapPostfix(
      Expression operand, Piece Function(Piece target) createPostfix) {
    _unwrapCall(operand);
    // If we don't have a preceding call to hang the postfix expression off of,
    // wrap it around the target expression. For example:
    //
    //     (list + another)!
    if (_calls.isEmpty) {
      _target = createPostfix(_target);
    } else {
      _calls.last.wrapPostfix(createPostfix);
    }
  }
}
