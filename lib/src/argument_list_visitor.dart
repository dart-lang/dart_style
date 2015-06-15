// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.argument_list_visitor;

import 'package:analyzer/analyzer.dart';

import 'chunk.dart';
import 'rule/argument.dart';
import 'rule/rule.dart';
import 'source_visitor.dart';

/// Helper class for [SourceVisitor] that handles visiting and writing an
/// [ArgumentList], including all of the special code needed to handle block
/// arguments.
class ArgumentListVisitor {
  final SourceVisitor _visitor;

  final ArgumentList _node;

  /// The positional arguments, in order.
  final List<Expression> _positional;

  /// The named arguments, in order.
  final List<Expression> _named;

  /// The set of arguments that are valid block literals.
  final Set<Expression> _blockArguments;

  /// The number of leading block arguments.
  ///
  /// If all arguments are block arguments, this counts them.
  final int _leadingBlockArguments;

  /// The number of trailing block arguments.
  ///
  /// If all arguments are block arguments, this is zero.
  final int _trailingBlockArguments;

  /// The rule used to split the bodies of all of the block arguments.
  Rule get _blockArgumentRule {
    // Lazy initialize.
    if (_blockRule == null && _blockArguments.isNotEmpty) {
      _blockRule = new SimpleRule(cost: Cost.splitBlocks);
    }

    return _blockRule;
  }
  Rule _blockRule;

  /// Returns `true` if there is only a single positional argument.
  bool get _isSingle => _positional.length == 1 && _named.isEmpty;

  /// Whether this argument list has any block arguments that are functions.
  bool get hasFunctionBlockArguments => _blockArguments.any(_isBlockFunction);

  bool get hasBlockArguments => _blockArguments.isNotEmpty;

  /// Whether this argument list should force the containing method chain to
  /// add a level of block nesting.
  bool get nestMethodArguments {
    // If there are block arguments, we don't want the method to force them to
    // the right.
    if (_blockArguments.isNotEmpty) return false;

    // Corner case: If there is just a single argument, don't bump the nesting.
    // This lets us avoid spurious indentation in cases like:
    //
    //     object.method(function(() {
    //       body;
    //     }));
    return _node.arguments.length > 1;
  }

  factory ArgumentListVisitor(SourceVisitor visitor, ArgumentList node) {
    // Assumes named arguments follow all positional ones.
    var positional = node.arguments
        .takeWhile((arg) => arg is! NamedExpression).toList();
    var named = node.arguments.skip(positional.length).toList();

    var blocks = node.arguments.where(_isBlockArgument).toSet();

    // Count the leading arguments that are block literals.
    var leadingBlocks = 0;
    for (var argument in node.arguments) {
      if (!blocks.contains(argument)) break;
      leadingBlocks++;
    }

    // Count the trailing arguments that are block literals.
    var trailingBlocks = 0;
    if (leadingBlocks != node.arguments.length) {
      for (var argument in node.arguments.reversed) {
        if (!blocks.contains(argument)) break;
        trailingBlocks++;
      }
    }

    // If only some of the named arguments are blocks, treat none of them as
    // blocks. Avoids cases like:
    //
    //     function(
    //         a: arg,
    //         b: [
    //       ...
    //     ]);
    if (trailingBlocks < named.length) trailingBlocks = 0;

    // Blocks must all be a prefix or suffix of the argument list (and not
    // both).
    if (leadingBlocks != blocks.length) leadingBlocks = 0;
    if (trailingBlocks != blocks.length) trailingBlocks = 0;

    // Ignore any blocks in the middle of the argument list.
    if (leadingBlocks == 0 && trailingBlocks == 0) {
      blocks.clear();
    }

    return new ArgumentListVisitor._(visitor, node, positional, named, blocks,
        leadingBlocks, trailingBlocks);
  }

  ArgumentListVisitor._(
      this._visitor,
      this._node,
      this._positional,
      this._named,
      this._blockArguments,
      this._leadingBlockArguments,
      this._trailingBlockArguments);

  /// Writes the argument list to the visitor's current writer.
  void write() {
    // If there is just one positional argument, it tends to look weird to
    // split before it, so try not to.
    if (_isSingle) _visitor.builder.startSpan();

    // Nest around the parentheses in case there are comments before or after
    // them.
    _visitor.builder.nestExpression();
    _visitor.builder.startSpan();
    _visitor.token(_node.leftParenthesis);

    var rule = _writePositional();
    _writeNamed(rule);

    _visitor.token(_node.rightParenthesis);

    _visitor.builder.endSpan();
    _visitor.builder.unnest();

    if (_isSingle) _visitor.builder.endSpan();
  }

  /// Writes the positional arguments, if any.
  PositionalRule _writePositional() {
    if (_positional.isEmpty) return null;

    // Allow splitting after "(".
    var rule;
    if (_positional.length == 1) {
      rule = new SinglePositionalRule(_blockArgumentRule);
    } else {
      // Only count the positional bodies in the positional rule.
      var leadingPositional = _leadingBlockArguments;
      if (_leadingBlockArguments == _node.arguments.length) {
        leadingPositional -= _named.length;
      }

      var trailingPositional = _trailingBlockArguments - _named.length;
      rule = new MultiplePositionalRule(
          _blockArgumentRule, leadingPositional, trailingPositional);
    }

    _visitor.builder.startRule(rule);
    rule.beforeArgument(_visitor.zeroSplit());

    // Try to not split the arguments.
    _visitor.builder.startSpan(Cost.positionalArguments);

    for (var argument in _positional) {
      _writeArgument(rule, argument);

      // Positional arguments split independently.
      if (argument != _positional.last) {
        rule.beforeArgument(_visitor.split());
      }
    }

    _visitor.builder.endSpan();
    _visitor.builder.endRule();

    return rule;
  }

  /// Writes the named arguments, if any.
  void _writeNamed(PositionalRule rule) {
    if (_named.isEmpty) return;

    var positionalRule = rule;
    var namedRule = new NamedRule(_blockArgumentRule);
    _visitor.builder.startRule(namedRule);

    // Let the positional args force the named ones to split.
    if (positionalRule != null) {
      positionalRule.setNamedArgsRule(namedRule);
    }

    // Split before the first named argument.
    namedRule.beforeArguments(
        _visitor.builder.split(space: _positional.isNotEmpty));

    for (var argument in _named) {
      _writeArgument(namedRule, argument);

      // Write the split.
      if (argument != _named.last) _visitor.split();
    }

    _visitor.builder.endRule();
  }

  void _writeArgument(ArgumentRule rule, Expression argument) {
    // If we're about to write a block argument, handle it specially.
    if (_blockArguments.contains(argument)) {
      if (rule != null) rule.beforeBlockArgument();

      // Tell it to use the rule we've already created.
      _visitor.setNextLiteralBodyRule(_blockArgumentRule);
    } else if (_node.arguments.length > 1) {
      // Corner case: If there is just a single argument, don't bump the
      // nesting. This lets us avoid spurious indentation in cases like:
      //
      //     function(function(() {
      //       body;
      //     }));
      _visitor.builder.startBlockArgumentNesting();
    }

    _visitor.visit(argument);

    if (_blockArguments.contains(argument)) {
      if (rule != null) rule.afterBlockArgument();
    } else if (_node.arguments.length > 1) {
      _visitor.builder.endBlockArgumentNesting();
    }

    // Write the trailing comma.
    if (argument != _node.arguments.last) {
      _visitor.token(argument.endToken.next);
    }
  }

  /// Returns true if [expression] denotes a block argument.
  ///
  /// That means a collection literal or a function expression with a block
  /// body. Block arguments can get special indentation to make them look more
  /// statement-like.
  static bool _isBlockArgument(Expression expression) {
    if (expression is NamedExpression) {
      expression = (expression as NamedExpression).expression;
    }

    // TODO(rnystrom): Should we step into parenthesized expressions?

    // Collections are bodies.
    if (expression is ListLiteral) return true;
    if (expression is MapLiteral) return true;

    // Curly body functions are.
    if (expression is! FunctionExpression) return false;
    var function = expression as FunctionExpression;
    return function.body is BlockFunctionBody;
  }

  /// Returns `true` if [expression] is a [FunctionExpression] with a block
  /// body.
  static bool _isBlockFunction(Expression expression) {
    if (expression is NamedExpression) {
      expression = (expression as NamedExpression).expression;
    }

    // Curly body functions are.
    if (expression is! FunctionExpression) return false;
    var function = expression as FunctionExpression;
    return function.body is BlockFunctionBody;
  }
}
