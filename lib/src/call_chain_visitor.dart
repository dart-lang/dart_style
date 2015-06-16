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

      if (expression is MethodInvocation && expression.target != null) {
        flatten(expression.target);
        calls.add(expression);
      } else if (expression is PropertyAccess && expression.target != null) {
        flatten(expression.target);
        calls.add(expression);
      } else if (expression is PrefixedIdentifier) {
        flatten(expression.prefix);
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
      properties =
          calls.takeWhile((call) => call is! MethodInvocation).toList();
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

    _visitor.visit(_target);

    // Leading properties split like positional arguments: either not at all,
    // before one ".", or before all of them.
    if (_properties.length == 1) {
      _visitor.soloZeroSplit();
      _writeCall(_properties.single);
    } else if (_properties.length > 1) {
      var argRule = new MultiplePositionalRule(null, 0, 0);
      _visitor.builder.startRule(argRule);

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

  /// Writes [call], which must be one of the supported expression types.
  void _writeCall(Expression call) {
    if (call is MethodInvocation) {
      _writeInvocation(call);
    } else if (call is PropertyAccess) {
      _writePropertyAccess(call);
    } else if (call is PrefixedIdentifier) {
      _writePrefixedIdentifier(call);
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

  void _writePropertyAccess(PropertyAccess property) {
    _visitor.token(property.operator);
    _visitor.visit(property.propertyName);
  }

  void _writePrefixedIdentifier(PrefixedIdentifier prefix) {
    _visitor.token(prefix.period);
    _visitor.visit(prefix.identifier);
  }

  /// If a [Rule] for the method chain is currently active, ends it.
  void _disableRule() {
    if (_ruleEnabled == false) return;

    _visitor.builder.endRule();
    _ruleEnabled = false;
  }

  /// Creates a new method chain [Rule] if one is not already active.
  void _enableRule() {
    if (_ruleEnabled) return;

    _visitor.builder.startRule();
    _ruleEnabled = true;
  }

  /// Ends the span wrapping the call chain if it hasn't ended already.
  void _endSpan() {
    if (_spanEnded) return;

    _visitor.builder.endSpan();
    _spanEnded = true;
  }
}
