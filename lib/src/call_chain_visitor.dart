// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import 'ast_extensions.dart';
import 'rule/call_chain.dart';
import 'rule/rule.dart';
import 'source_visitor.dart';

/// Helper class for [SourceVisitor] that handles visiting and writing a
/// chained series of "selectors": method invocations, property accesses,
/// prefixed identifiers, index expressions, and null-assertion operators.
///
/// In the AST, selectors are nested bottom up such that this expression:
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
/// to left. It's easier to format that if we organize them as a linear series
/// of selectors from left to right. Further, we want to organize it into a
/// two-tier hierarchy. We have an outer list of method calls and property
/// accesses. Then each of those may have one or more postfix selectors
/// attached: indexers, null-assertions, or invocations. This mirrors how they
/// are formatted.
class CallChainVisitor {
  final SourceVisitor _visitor;

  /// The initial target of the call chain.
  ///
  /// This may be any expression except [MethodInvocation], [PropertyAccess] or
  /// [PrefixedIdentifier].
  final Expression _target;

  /// The list of dotted names ([PropertyAccess] and [PrefixedIdentifier]) at
  /// the start of the call chain.
  ///
  /// This will be empty if the [_target] is not a [SimpleIdentifier].
  final List<_Selector> _properties;

  /// The mixed method calls and property accesses in the call chain in the
  /// order that they appear in the source reading from left to right.
  final List<_Selector> _calls;

  final CallChainRule _callRule = CallChainRule();

  /// Creates a new call chain visitor for [visitor] for the method chain
  /// contained in [node].
  ///
  /// The [node] is the outermost expression containing the chained "."
  /// operators and must be a [MethodInvocation], [PropertyAccess] or
  /// [PrefixedIdentifier].
  factory CallChainVisitor(SourceVisitor visitor, Expression node) {
    // Flatten the call chain tree to a list of selectors with postfix
    // expressions.
    var calls = <_Selector>[];
    var target = _unwrapTarget(node, calls);

    // An expression that starts with a series of dotted names gets treated a
    // little specially. We don't force leading properties to split with the
    // rest of the chain. Allows code like:
    //
    //     address.street.number
    //       .toString()
    //       .length;
    var properties = <_Selector>[];
    if (_unwrapNullAssertion(target) is SimpleIdentifier) {
      properties = calls.takeWhile((call) => call.isProperty).toList();
    }

    calls.removeRange(0, properties.length);

    // Determine which method calls should force the call chain to split if
    // their arguments split.
    if (calls.length > 1) {
      // The last call in the chain doesn't force the chain to split. Also, any
      // calls with no arguments don't count when finding the "last" call.
      var lastNonEmptyCall = calls.length - 1;
      for (var i = calls.length - 1; i >= 0; i--) {
        var call = calls[i];
        if (call is _MethodSelector &&
            call._node.argumentList.arguments.isNotEmpty) {
          lastNonEmptyCall = i;
          break;
        }
      }

      for (var i = 0; i < lastNonEmptyCall; i++) {
        var call = calls[i];
        if (call is _MethodSelector) {
          call._splitsChain = true;
        }
      }
    }

    return CallChainVisitor._(visitor, target, properties, calls);
  }

  CallChainVisitor._(
      this._visitor, this._target, this._properties, this._calls);

  /// Builds chunks for the call chain.
  void visit() {
    _visitor.builder.nestExpression();
    _visitor.builder.startBlockArgumentNesting();

    // Try to keep the entire method invocation one line.
    _visitor.builder.startSpan();

    Rule? propertyRule;

    // If a split in the target expression forces the first `.` to split, then
    // start the rule now so that it surrounds the target.
    var splitOnTarget = _forcesSplit(_target);
    if (splitOnTarget) {
      if (_properties.isNotEmpty) {
        propertyRule = Rule();
        _visitor.builder.startLazyRule(propertyRule);
      } else {
        _visitor.builder.startLazyRule(_callRule);
        _callRule.enableSplitOnInnerRules();
      }
    }

    // TODO: This is a really weird hack. Figure out why it's needed and do
    // something cleaner.
    // Push an empty nesting level around the target so that the block
    // for the target doesn't use the chain's rule for its nesting.
    _visitor.builder.nestExpression(indent: 0);
    _visitor.builder.startBlockArgumentNesting();

    _visitor.visit(_target);

    _visitor.builder.endBlockArgumentNesting();
    _visitor.builder.unnest();

    if (_properties.isNotEmpty) {
      if (!splitOnTarget) {
        propertyRule = Rule();
        _visitor.builder.startRule(propertyRule);
      }

      for (var property in _properties) {
        _visitor.zeroSplit();
        property.write(this);
      }
      _visitor.builder.endRule();
    }

    if (_calls.isNotEmpty) {
      if (!splitOnTarget || propertyRule != null) {
        _visitor.builder.startRule(_callRule);
      }

      _callRule.disableSplitOnInnerRules();

      // If the properties split, the calls do too.
      if (propertyRule != null) propertyRule.constrainWhenSplit(_callRule);

      for (var call in _calls) {
        _visitor.zeroSplit();
        call.write(this);
      }

      _visitor.builder.endRule();
    }

    _visitor.builder.endSpan();
    _visitor.builder.endBlockArgumentNesting();
    _visitor.builder.unnest();
  }

  /// Returns `true` if the method chain should split if a split occurs inside
  /// [expression].
  ///
  /// In most cases, splitting in a method chain's target forces the chain to
  /// split too:
  ///
  ///      receiver(very, long, argument,
  ///              list)                    // <-- Split here...
  ///          .method();                   //     ...forces split here.
  ///
  /// However, if the target is a collection or function literal (or an
  /// argument list ending in one of those), we don't want to split:
  ///
  ///      receiver(inner(() {
  ///        ;
  ///      }).method();                     // <-- Unsplit.
  bool _forcesSplit(Expression expression) {
    // TODO(rnystrom): Other cases we may want to consider handling and
    // recursing into:
    // * The right operand in an infix operator call.
    // * The body of a `=>` function.

    // Unwrap parentheses.
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }

    // Don't split right after a collection literal.
    if (expression.isCollectionLiteral) return false;

    // Don't split right after a non-empty curly-bodied function.
    if (expression is FunctionExpression) {
      if (expression.body is! BlockFunctionBody) return false;

      return (expression.body as BlockFunctionBody).block.statements.isEmpty;
    }

    // If the expression ends in an argument list, base the splitting on the
    // last argument.
    ArgumentList? argumentList;
    if (expression is MethodInvocation) {
      argumentList = expression.argumentList;
    } else if (expression is InstanceCreationExpression) {
      argumentList = expression.argumentList;
    } else if (expression is FunctionExpressionInvocation) {
      argumentList = expression.argumentList;
    }

    // Any other kind of expression always splits.
    if (argumentList == null) return true;
    if (argumentList.arguments.isEmpty) return true;

    return false;
  }
}

/// One "selector" in a method call chain.
///
/// Each selector is a method call or property access. It may be followed by
/// one or more postfix expressions, which can be index expressions or
/// null-assertion operators. These are not treated like their own selectors
/// because the formatter attaches them to the previous method call or property
/// access:
///
///     receiver
///         .method(arg)[index]
///         .another()!
///         .third();
sealed class _Selector {
  /// The series of index and/or null-assertion postfix selectors that follow
  /// and are attached to this one.
  ///
  /// Elements in this list will either be [IndexExpression] or
  /// [PostfixExpression].
  final List<Expression> _postfixes = [];

  /// Whether this selector is a property access as opposed to a method call.
  bool get isProperty => true;

  /// Whether this selector is a method call whose arguments are block
  /// formatted.
  bool get isBlockCall => false;

  /// Write the selector portion of the expression wrapped by this [_Selector]
  /// using [visitor], followed by any postfix selectors.
  void write(CallChainVisitor visitor) {
    writeSelector(visitor);

    // Write any trailing index and null-assertion operators.
    visitor._visitor.builder.nestExpression();
    for (var postfix in _postfixes) {
      if (postfix is FunctionExpressionInvocation) {
        // Allow splitting between the invocations if needed.
        visitor._visitor.soloZeroSplit();

        visitor._visitor.visit(postfix.typeArguments);
        visitor._visitor.visitArgumentList(postfix.argumentList);
      } else if (postfix is IndexExpression) {
        visitor._visitor.finishIndexExpression(postfix);
      } else if (postfix is PostfixExpression) {
        assert(postfix.operator.type == TokenType.BANG);
        visitor._visitor.token(postfix.operator);
      } else {
        // Unexpected type.
        assert(false);
      }
    }
    visitor._visitor.builder.unnest();
  }

  /// Subclasses implement this to write their selector.
  void writeSelector(CallChainVisitor visitor);
}

class _MethodSelector extends _Selector {
  final MethodInvocation _node;

  /// Whether a split in this method's argument list causes the method chain
  /// to split.
  bool _splitsChain = false;

  _MethodSelector(this._node);

  @override
  bool get isProperty => false;

  @override
  bool get isBlockCall =>
      _node.argumentList.arguments.isEmpty ||
      _node.argumentList.arguments.length == 1 &&
          _node.argumentList.arguments.blockArgument != null;

  @override
  void writeSelector(CallChainVisitor visitor) {
    visitor._visitor.token(_node.operator);
    visitor._visitor.token(_node.methodName.token);

    // TODO: This is a really weird hack. Figure out why it's needed and do
    // something cleaner.
    // Push an empty nesting level around the argument list so that the block
    // for the argument list doesn't use the chain's rule for its nesting.
    visitor._visitor.builder.nestExpression(indent: 0);
    visitor._visitor.builder.startBlockArgumentNesting();

    visitor._visitor.builder.nestExpression();

    visitor._visitor.visit(_node.typeArguments);

    var rule = visitor._visitor.visitArgumentList(_node.argumentList);

    if (rule != null && _splitsChain) {
      rule.constrainWhenSplit(visitor._callRule);
    }

    visitor._visitor.builder.unnest();
    visitor._visitor.builder.endBlockArgumentNesting();
    visitor._visitor.builder.unnest();
  }
}

class _PrefixedSelector extends _Selector {
  final PrefixedIdentifier _node;

  _PrefixedSelector(this._node);

  @override
  void writeSelector(CallChainVisitor visitor) {
    visitor._visitor.token(_node.period);
    visitor._visitor.visit(_node.identifier);
  }
}

class _PropertySelector extends _Selector {
  final PropertyAccess _node;

  _PropertySelector(this._node);

  @override
  void writeSelector(CallChainVisitor visitor) {
    visitor._visitor.token(_node.operator);
    visitor._visitor.visit(_node.propertyName);
  }
}

/// If [expression] is a null-assertion operator, returns its operand.
Expression _unwrapNullAssertion(Expression expression) {
  if (expression is PostfixExpression &&
      expression.operator.type == TokenType.BANG) {
    return expression.operand;
  }

  return expression;
}

/// Given [node], which is the outermost expression for some call chain,
/// recursively traverses the selectors to fill in the list of [calls].
///
/// Returns the remaining target expression that precedes the method chain.
/// For example, given:
///
///     foo.bar()!.baz[0][1].bang()
///
/// This returns `foo` and fills calls with:
///
///     selector  postfixes
///     --------  ---------
///     .bar()    !
///     .baz      [0], [1]
///     .bang()
Expression _unwrapTarget(Expression node, List<_Selector> calls) {
  // Don't include things that look like static method or constructor
  // calls in the call chain because that tends to split up named
  // constructors from their class.
  if (node.looksLikeStaticCall) return node;

  // Selectors.
  if (node is MethodInvocation && node.target != null) {
    return _unwrapSelector(node.target!, _MethodSelector(node), calls);
  }

  if (node is PropertyAccess && node.target != null) {
    return _unwrapSelector(node.target!, _PropertySelector(node), calls);
  }

  if (node is PrefixedIdentifier) {
    return _unwrapSelector(node.prefix, _PrefixedSelector(node), calls);
  }

  // Postfix expressions.
  if (node is IndexExpression && node.target != null) {
    return _unwrapPostfix(node, node.target!, calls);
  }

  if (node is FunctionExpressionInvocation) {
    return _unwrapPostfix(node, node.function, calls);
  }

  if (node is PostfixExpression && node.operator.type == TokenType.BANG) {
    return _unwrapPostfix(node, node.operand, calls);
  }

  // Otherwise, it isn't a selector so we're done.
  return node;
}

Expression _unwrapPostfix(
    Expression node, Expression target, List<_Selector> calls) {
  target = _unwrapTarget(target, calls);

  // If we don't have a preceding selector to hang the postfix expression off
  // of, don't unwrap it and leave it attached to the target expression. For
  // example:
  //
  //     (list + another)[index]
  if (calls.isEmpty) return node;

  calls.last._postfixes.add(node);
  return target;
}

Expression _unwrapSelector(
    Expression target, _Selector selector, List<_Selector> calls) {
  target = _unwrapTarget(target, calls);
  calls.add(selector);
  return target;
}
