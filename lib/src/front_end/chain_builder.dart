// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../constants.dart';
import '../piece/chain.dart';
import '../piece/leading_comment.dart';
import '../piece/list.dart';
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
final class ChainBuilder {
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
      _visitTarget(cascade.target, cascadeTarget: true);

      // When [_root] is a cascade, the chain is the series of cascade sections.
      for (var section in cascade.cascadeSections) {
        var piece = _visitor.nodePiece(section);

        var callType = switch (section) {
          // Force the cascade to split if there are leading comments before
          // the cascade section to avoid:
          //
          //     target// comment
          //     ..method(
          //       argument,
          //     );
          _ when piece is LeadingCommentPiece => CallType.unsplittableCall,

          // If the section is itself a method chain, then force the cascade to
          // split if the method does, as in:
          //
          //     cascadeTarget
          //       ..methodTarget.method(
          //         argument,
          //       );
          MethodInvocation(target: _?) => CallType.unsplittableCall,

          // Otherwise, allow a direct method call in the cascade to not split
          // the cascade if the arguments can split, as in:
          //
          //     cascadeTarget..method(
          //       argument,
          //     );
          MethodInvocation(argumentList: var args)
              when args.arguments.canSplit(args.rightParenthesis) =>
            CallType.splittableCall,
          _ => CallType.unsplittableCall,
        };

        _calls.add(ChainCall(piece, callType));
      }
    } else {
      _unwrapCall(_root);
    }
  }

  /// Builds a [ChainPiece] for a series of cascade sections.
  Piece buildCascade() {
    // If there is only a single section and it can block split, allow it:
    //
    //     target..cascade(
    //       argument,
    //     );
    var blockCallIndex = _calls.length == 1 && _calls.single.canSplit ? 0 : -1;

    var chain = ChainPiece(_target, _calls,
        cascade: true,
        indent: Indent.cascade,
        blockCallIndex: blockCallIndex,
        allowSplitInTarget: _allowSplitInTarget);

    if (!(_root as CascadeExpression).allowInline) chain.pin(State.split);

    return chain;
  }

  /// Builds a [ChainPiece] for a series of method calls and property accesses.
  ///
  /// If [isCascadeTarget] is `true`, then this call chain occurs as the target
  /// of a cascade expression, as in:
  ///
  ///     call.chain()..cascade();
  Piece build({required bool isCascadeTarget}) {
    // If there are no calls, there's no chain.
    if (_calls.isEmpty) return _target;

    // Count the number of contiguous properties at the beginning of the chain.
    var leadingProperties = 0;
    while (leadingProperties < _calls.length &&
        _calls[leadingProperties].type == CallType.property) {
      leadingProperties++;
    }

    // Count the number of leading properties and unsplittable calls.
    var leadingUnsplittable = leadingProperties;
    while (leadingUnsplittable < _calls.length &&
        !_calls[leadingUnsplittable].canSplit) {
      leadingUnsplittable++;
    }

    // See if we can block format the chain on one of its calls. We allow the
    // last call in a chain to block format:
    //
    //     target.property.method().last(
    //       argument,
    //     );
    //
    // But we only allow it to do so if either the preceding calls can't split
    // (as in the preceding example) or the last call is actually a block
    // formatted argument list (like a collection or function literal) and not
    // just a split argument list. So this is OK:
    //
    //     target.method(1, 2).last([
    //       element,
    //     ]);
    //
    // Even though `method()` takes arguments and can split, we still allow the
    // chain to block format on the last call because that call is itself a
    // block formatted argument list with a collection literal, and not just a
    // split argument list.
    //
    // Further, we allow the second-to-last call in the chain to be the block
    // formatted call if the last call is a property or unsplittable call and
    // the preceding call can block format. This allows for common hanging
    // operations like `toList()` as in:
    //
    //     things.map((element) {
    //       return doStuffTo(element);
    //     }).toList();
    var lastCallIndex = _calls.length - 1;
    if (!_calls[lastCallIndex].canSplit &&
        _calls.length > 1 &&
        _calls[lastCallIndex - 1].type == CallType.blockFormatCall) {
      lastCallIndex = _calls.length - 2;
    }

    var blockCallIndex = -1;
    if (leadingUnsplittable == lastCallIndex &&
        _calls[lastCallIndex].canSplit) {
      blockCallIndex = lastCallIndex;
    } else if (_calls[lastCallIndex].type == CallType.blockFormatCall) {
      blockCallIndex = lastCallIndex;
    }

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
    return ChainPiece(_target, _calls,
        cascade: false,
        indent: isCascadeTarget ? Indent.cascade : Indent.expression,
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
      case MethodInvocation(:var target?):
        _unwrapCall(target);

        var callType = CallType.unsplittableCall;

        if (expression.argumentList.arguments
            .canSplit(expression.argumentList.rightParenthesis)) {
          callType = CallType.splittableCall;
        }

        var callPiece = _visitor.pieces.build(() {
          _visitor.pieces.token(expression.operator);
          _visitor.pieces.visit(expression.methodName);
          _visitor.pieces.visit(expression.typeArguments);

          // Create the argument piece manually so that we can see if it has a
          // block argument or not.
          var arguments = _visitor.pieces.build(() {
            _visitor.writeArgumentList(
                expression.argumentList.leftParenthesis,
                expression.argumentList.arguments,
                expression.argumentList.rightParenthesis);
          });

          if (arguments is ListPiece && arguments.hasBlockElement) {
            callType = CallType.blockFormatCall;
          }

          _visitor.pieces.add(arguments);
        });

        _calls.add(ChainCall(callPiece, callType));

      case PropertyAccess(:var target?):
        _unwrapCall(target);

        var piece = _visitor.pieces.build(() {
          _visitor.pieces.token(expression.operator);
          _visitor.pieces.visit(expression.propertyName);
        });

        _calls.add(ChainCall(piece, CallType.property));

      case PrefixedIdentifier(:var prefix):
        _unwrapCall(prefix);

        var piece = _visitor.pieces.build(() {
          _visitor.pieces.token(expression.period);
          _visitor.pieces.visit(expression.identifier);
        });

        _calls.add(ChainCall(piece, CallType.property));

      // Postfix expressions.
      case FunctionExpressionInvocation():
        _unwrapPostfix(expression.function, (target) {
          return _visitor.pieces.build(() {
            _visitor.pieces.add(target);
            _visitor.pieces.visit(expression.typeArguments);
            _visitor.pieces.visit(expression.argumentList);
          });
        });

      case IndexExpression(:var target?):
        // We check for a non-null target because the target may be `null` if
        // the chain we are building is itself in a cascade section that begins
        // with an index expression like:
        //
        //     object..[index].chain();
        _unwrapPostfix(target, (target) {
          return _visitor.pieces.build(() {
            _visitor.pieces.add(target);
            _visitor.writeIndexExpression(expression);
          });
        });

      case PostfixExpression() when expression.operator.type == TokenType.BANG:
        _unwrapPostfix(expression.operand, (target) {
          return _visitor.pieces.build(() {
            _visitor.pieces.add(target);
            _visitor.pieces.token(expression.operator);
          });
        });

      default:
        // Otherwise, it isn't a selector so we've reached the target.
        _visitTarget(expression);
    }
  }

  /// Creates and stores the resulting Piece for [target] as well as whether it
  /// allows being split.
  ///
  /// If [cascadeTarget] is `true`, then this is the target of a cascade
  /// expression. Otherwise, it's the target of a call chain.
  void _visitTarget(Expression target, {bool cascadeTarget = false}) {
    _allowSplitInTarget = target.canBlockSplit;
    _target = _visitor.nodePiece(target,
        context: cascadeTarget ? NodeContext.cascadeTarget : NodeContext.none);
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
