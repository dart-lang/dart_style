// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.call_chain_visitor;

import 'package:analyzer/analyzer.dart';

import 'argument_list_visitor.dart';
import 'rule/argument.dart';
import 'source_visitor.dart';

/// Helper class for [SourceVisitor] that handles visiting and writing a
/// chained series of method invocations, property accesses, and/or prefix
/// expressions. In other words, anything using the "." operator.
class CallChainVisitor {
  final SourceVisitor _visitor;

  /// The initial target of the call chain.
  ///
  /// This may be any expression except [MethodInvocation], [PropertyAccess] or
  /// [PrefixedIdentifier].
  final Expression _target;

  /// The list of dotted names ([PropertyAccess] and [PrefixedIdentifier] at
  /// the start of the call chain.
  ///
  /// This will be empty if the [_target] is not a [SimpleIdentifier].
  final List<Expression> _properties;

  /// The mixed method calls and property accesses in the call chain in the
  /// order that they appear in the source.
  final List<Expression> _calls;

  /// Whether or not a [Rule] is currently active for the call chain.
  bool _ruleEnabled = false;

  /// Whether or not the span wrapping the call chain is currently active.
  bool _spanEnded = false;

  /// Creates a new call chain visitor for [visitor] starting with [node].
  ///
  /// The [node] is the outermost expression containing the chained "."
  /// operators and must be a [MethodInvocation], [PropertyAccess] or
  /// [PrefixedIdentifier].
  factory CallChainVisitor(SourceVisitor visitor, Expression node) {
    var target;

    // Recursively walk the chain of calls and turn the tree into a list.
    var calls = [];
    flatten(expression) {
      target = expression;

      // Treat index expressions where the target is a valid call in a method
      // chain as being part of the call. Handles cases like:
      //
      //     receiver
      //         .property
      //         .property[0]
      //         .property
      //         .method()[1][2];
      var call = expression;
      while (call is IndexExpression) call = call.target;

      if (call is MethodInvocation && call.target != null) {
        flatten(call.target);
        calls.add(expression);
      } else if (call is PropertyAccess && call.target != null) {
        flatten(call.target);
        calls.add(expression);
      } else if (call is PrefixedIdentifier) {
        flatten(call.prefix);
        calls.add(expression);
      }
    }

    flatten(node);

    // An expression that starts with a series of dotted names gets treated a
    // little specially. We don't force leading properties to split with the
    // rest of the chain. Allows code like:
    //
    //     address.street.number
    //       .toString()
    //       .length;
    var properties = [];
    if (target is SimpleIdentifier) {
      properties = calls.takeWhile((call) {
        // Step into index expressions to see what the index is on.
        while (call is IndexExpression) call = call.target;
        return call is! MethodInvocation;
      }).toList();
    }

    calls.removeRange(0, properties.length);

    return new CallChainVisitor._(visitor, target, properties, calls);
  }

  CallChainVisitor._(
      this._visitor, this._target, this._properties, this._calls);

  /// Builds chunks for the call chain.
  ///
  /// If [unnest] is `false` than this will not close the expression nesting
  /// created for the call chain and the caller must end it. Used by cascades
  /// to force a cascade after a method chain to be more deeply nested than
  /// the methods.
  void visit({bool unnest}) {
    if (unnest == null) unnest = true;

    _visitor.builder.nestExpression();

    // Try to keep the entire method invocation one line.
    _visitor.builder.startSpan();

    // If a split in the target expression forces the first `.` to split, then
    // start the rule now so that it surrounds the target.
    var splitOnTarget = _forcesSplit(_target);
    var argRule;

    if (splitOnTarget) {
      if (_properties.length > 1) {
        argRule = new MultiplePositionalRule(null, 0, 0);
        _visitor.builder.startLazyRule(argRule);
      } else if (_calls.isNotEmpty) {
        _enableRule(lazy: true);
      }
    }

    _visitor.visit(_target);

    // Leading properties split like positional arguments: either not at all,
    // before one ".", or before all of them.
    if (_properties.length == 1) {
      _visitor.soloZeroSplit();
      _writeCall(_properties.single);
    } else if (_properties.length > 1) {
      if (!splitOnTarget) {
        argRule = new MultiplePositionalRule(null, 0, 0);
        _visitor.builder.startRule(argRule);
      }

      for (var property in _properties) {
        argRule.beforeArgument(_visitor.zeroSplit());
        _writeCall(property);
      }

      _visitor.builder.endRule();
    }

    // The remaining chain of calls generally split atomically (either all or
    // none), except that block arguments may split a chain into two parts.
    for (var call in _calls) {
      _enableRule();
      _visitor.zeroSplit();
      _writeCall(call);
    }

    _disableRule();
    _endSpan();

    if (unnest) _visitor.builder.unnest();
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
    // * ParenthesizedExpression.
    // * The right operand in an infix operator call.
    // * The body of a `=>` function.

    // Don't split right after a collection literal.
    if (expression is ListLiteral) return false;
    if (expression is MapLiteral) return false;

    // Don't split right after a non-empty curly-bodied function.
    if (expression is FunctionExpression) {
      var function = expression as FunctionExpression;

      if (function.body is! BlockFunctionBody) return false;

      return (function.body as BlockFunctionBody).block.statements.isEmpty;
    }

    // If the expression ends in an argument list, base the splitting on the
    // last argument.
    var argumentList;
    if (expression is MethodInvocation) {
      argumentList = (expression as MethodInvocation).argumentList;
    } else if (expression is InstanceCreationExpression) {
      argumentList = (expression as InstanceCreationExpression).argumentList;
    } else if (expression is FunctionExpressionInvocation) {
      argumentList = (expression as FunctionExpressionInvocation).argumentList;
    }

    // Any other kind of expression always splits.
    if (argumentList == null) return true;
    if (argumentList.arguments.isEmpty) return true;

    var argument = argumentList.arguments.last;
    if (argument is NamedExpression) argument = argument.expression;

    // TODO(rnystrom): This logic is similar (but not identical) to
    // ArgumentListVisitor.hasBlockArguments. They overlap conceptually and
    // both have their own peculiar heuristics. It would be good to unify and
    // rationalize them.

    return _forcesSplit(argument);
  }

  /// Writes [call], which must be one of the supported expression types.
  void _writeCall(Expression call) {
    if (call is IndexExpression) {
      _visitor.builder.nestExpression();
      _writeCall(call.target);
      _visitor.finishIndexExpression(call);
      _visitor.builder.unnest();
    } else if (call is MethodInvocation) {
      _writeInvocation(call);
    } else if (call is PropertyAccess) {
      _visitor.token(call.operator);
      _visitor.visit(call.propertyName);
    } else if (call is PrefixedIdentifier) {
      _visitor.token(call.period);
      _visitor.visit(call.identifier);
    } else {
      // Unexpected type.
      assert(false);
    }
  }

  void _writeInvocation(MethodInvocation invocation) {
    _visitor.token(invocation.operator);
    _visitor.token(invocation.methodName.token);

    // If a method's argument list includes any block arguments, there's a
    // good chance it will split. Treat the chains before and after that as
    // separate unrelated method chains.
    //
    // This is kind of a hack since it treats methods before and after a
    // collection literal argument differently even when the collection
    // doesn't split, but it works out OK in practice.
    //
    // Doing something more precise would require setting up a bunch of complex
    // constraints between various rules. You'd basically have to say "if the
    // block argument splits then allow the chain after it to split
    // independently, otherwise force it to follow the previous chain".
    var args = new ArgumentListVisitor(_visitor, invocation.argumentList);

    // Stop the rule after the last call, but before its arguments. This
    // allows unsplit chains where the last argument list wraps, like:
    //
    //     foo().bar().baz(
    //         argument, list);
    //
    // Also stop the rule to split the argument list at any call with
    // block arguments. This makes for nicer chains of higher-order method
    // calls, like:
    //
    //     items.map((element) {
    //       ...
    //     }).where((element) {
    //       ...
    //     });
    if (invocation == _calls.last || args.hasBlockArguments) _disableRule();

    if (args.nestMethodArguments) _visitor.builder.startBlockArgumentNesting();

    // For a single method call on an identifier, stop the span before the
    // arguments to make it easier to keep the call name with the target. In
    // other words, prefer:
    //
    //     target.method(
    //         argument, list);
    //
    // Over:
    //
    //     target
    //         .method(argument, list);
    //
    // Alternatively, the way to think of this is try to avoid splitting on the
    // "." when calling a single method on a single name. This is especially
    // important because the identifier is often a library prefix, and splitting
    // there looks really odd.
    if (_properties.isEmpty &&
        _calls.length == 1 &&
        _target is SimpleIdentifier) {
      _endSpan();
    }

    _visitor.visit(invocation.argumentList);

    if (args.nestMethodArguments) _visitor.builder.endBlockArgumentNesting();
  }

  /// If a [Rule] for the method chain is currently active, ends it.
  void _disableRule() {
    if (_ruleEnabled == false) return;

    _visitor.builder.endRule();
    _ruleEnabled = false;
  }

  /// Creates a new method chain [Rule] if one is not already active.
  void _enableRule({bool lazy: false}) {
    if (_ruleEnabled) return;

    if (lazy) {
      _visitor.builder.startLazyRule();
    } else {
      _visitor.builder.startRule();
    }

    _ruleEnabled = true;
  }

  /// Ends the span wrapping the call chain if it hasn't ended already.
  void _endSpan() {
    if (_spanEnded) return;

    _visitor.builder.endSpan();
    _spanEnded = true;
  }
}
