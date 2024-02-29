// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../constants.dart';
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

  /// The outermost expression being converted to a chain.
  ///
  /// If it's a [CascadeExpression], then the chain is the cascade sections.
  /// Otherwise, it's some kind of method call or property access and the chain
  /// is the nested series of selector subexpressions.
  final Expression _root;

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

  ChainBuilder(this._visitor, this._root) {
    if (_root case CascadeExpression cascade) {
      _visitTarget(cascade.target);

      // When [_root] is a cascade, the chain is the series of cascade sections.
      for (var section in cascade.cascadeSections) {
        var piece = _visitor.nodePiece(section);

        var callType = switch (section) {
          MethodInvocation(argumentList: var args)
              when args.arguments.canSplit(args.rightParenthesis) =>
            CallType.splittableCall,
          MethodInvocation() => CallType.unsplittableCall,
          _ => CallType.property,
        };

        _calls.add(ChainCall(piece, callType));
      }
    } else {
      _unwrapCall(_root);
    }
  }

  Piece build() {
    if (_root case CascadeExpression cascade) {
      // If there is only a single section and it can block split, allow it:
      //
      //     target..cascade(
      //       argument,
      //     );
      var blockCallIndex =
          _calls.length == 1 && _calls.single.canSplit ? 0 : -1;

      var chain = ChainPiece(_target, _calls,
          indent: Indent.cascade,
          blockCallIndex: blockCallIndex,
          allowSplitInTarget: _allowSplitInTarget);

      if (!cascade.allowInline) chain.pin(State.split);

      return chain;
    }

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

    // If a method chain appears as the target of a cascade, then we only
    // indent the method chain +2. That way, with the cascade's own +2, the
    // result is a total of +4. This looks more natural than indenting the
    // method chain +4 relative to the cascade's +2:
    //
    //     // Bad:
    //     object
    //           .method()
    //           .method()
    //       ..x = 1
    //       ..y = 2;
    //
    //     // Better:
    //     object
    //         .method()
    //         .method()
    //       ..x = 1
    //       ..y = 2;
    var indent =
        _root.parent is CascadeExpression ? Indent.cascade : Indent.expression;

    return ChainPiece(_target, _calls,
        indent: indent,
        leadingProperties: leadingProperties,
        blockCallIndex: blockCallIndex,
        allowSplitInTarget: _allowSplitInTarget);
  }

  /// Given [expression], which is the expression for some call chain, traverses
  /// the selectors to fill in the list of [_calls].
  ///
  /// Otherwise, it's a method chain, and this recursively calls itself for the
  /// targets to unzip and flatten the nested selector expressions. Then it
  /// initializes [_target] with the innermost subexpression that isn't a part
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
      case AssignmentExpression():
        var piece = _visitor.createAssignment(expression.leftHandSide,
            expression.operator, expression.rightHandSide);
        _calls.add(ChainCall(piece, CallType.property));

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
    // make it part of the target expression. For example:
    //
    //     (list + another)!
    if (_calls.isEmpty) {
      _target = createPostfix(_target);
    } else {
      _calls.last.wrapPostfix(createPostfix);
    }
  }
}
