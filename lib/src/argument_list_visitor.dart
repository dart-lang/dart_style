// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

// TODO: Eliminate this or simplify it more.
bool hasBlockArguments(ArgumentList node) {
  var functionRange = _contiguousFunctions(node.arguments);
  if (functionRange != null) return true;

  var arguments = node.arguments;

  var blocks = <Expression, Token>{};
  for (var argument in arguments) {
    var bracket = _blockToken(argument);
    if (bracket != null) blocks[argument] = bracket;
  }

  // Count the leading arguments that are blocks.
  var leadingBlocks = 0;
  for (var argument in arguments) {
    if (!blocks.containsKey(argument)) break;
    leadingBlocks++;
  }

  // Count the trailing arguments that are blocks.
  var trailingBlocks = 0;
  if (leadingBlocks != arguments.length) {
    for (var argument in arguments.reversed) {
      if (!blocks.containsKey(argument)) break;
      trailingBlocks++;
    }
  }

  // Blocks must all be a prefix or suffix of the argument list (and not
  // both).
  if (leadingBlocks != blocks.length) leadingBlocks = 0;
  if (trailingBlocks != blocks.length) trailingBlocks = 0;

  // Ignore any blocks in the middle of the argument list.
  if (leadingBlocks == 0 && trailingBlocks == 0) blocks.clear();

  return blocks.isNotEmpty;
}

/// Look for a single contiguous range of block function [arguments] that
/// should receive special formatting.
///
/// Returns a list of (start, end] indexes if found, otherwise returns `null`.
List<int>? _contiguousFunctions(List<Expression> arguments) {
  int? functionsStart;
  var functionsEnd = -1;

  // Find the range of block function arguments, if any.
  for (var i = 0; i < arguments.length; i++) {
    var argument = arguments[i];
    if (_isBlockFunction(argument)) {
      functionsStart ??= i;

      // The functions must be one contiguous section.
      if (functionsEnd != -1 && functionsEnd != i) return null;

      functionsEnd = i + 1;
    }
  }

  if (functionsStart == null) return null;

  // Edge case: If all of the arguments are named, but they aren't all
  // functions, then don't handle the functions specially. A function with a
  // bunch of named arguments tends to look best when they are all lined up,
  // even the function ones (unless they are all functions).
  //
  // Prefers:
  //
  //     function(
  //         named: () {
  //           something();
  //         },
  //         another: argument);
  //
  // Over:
  //
  //     function(named: () {
  //       something();
  //     },
  //         another: argument);
  if (_isAllNamed(arguments) &&
      (functionsStart > 0 || functionsEnd < arguments.length)) {
    return null;
  }

  // Edge case: If all of the function arguments are named and there are
  // other named arguments that are "=>" functions, then don't treat the
  // block-bodied functions specially. In a mixture of the two function
  // styles, it looks cleaner to treat them all like normal expressions so
  // that the named arguments line up.
  if (_isAllNamed(arguments.sublist(functionsStart, functionsEnd))) {
    bool isNamedArrow(Expression expression) {
      if (expression is! NamedExpression) return false;
      expression = expression.expression;

      return expression is FunctionExpression &&
          expression.body is ExpressionFunctionBody;
    }

    for (var i = 0; i < functionsStart; i++) {
      if (isNamedArrow(arguments[i])) return null;
    }

    for (var i = functionsEnd; i < arguments.length; i++) {
      if (isNamedArrow(arguments[i])) return null;
    }
  }

  return [functionsStart, functionsEnd];
}

/// Returns `true` if every expression in [arguments] is named.
bool _isAllNamed(List<Expression> arguments) =>
    arguments.every((argument) => argument is NamedExpression);

/// Returns `true` if [expression] is a [FunctionExpression] with a non-empty
/// block body.
bool _isBlockFunction(Expression expression) {
  if (expression is NamedExpression) expression = expression.expression;

  // Allow functions wrapped in dotted method calls like "a.b.c(() { ... })".
  if (expression is MethodInvocation) {
    if (!_isValidWrappingTarget(expression.target)) return false;
    if (expression.argumentList.arguments.length != 1) return false;

    return _isBlockFunction(expression.argumentList.arguments.single);
  }

  if (expression is InstanceCreationExpression) {
    if (expression.argumentList.arguments.length != 1) return false;

    return _isBlockFunction(expression.argumentList.arguments.single);
  }

  // Allow immediately-invoked functions like "() { ... }()".
  if (expression is FunctionExpressionInvocation) {
    if (expression.argumentList.arguments.isNotEmpty) return false;

    expression = expression.function;
  }

  // Unwrap parenthesized expressions.
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }

  // Must be a function.
  if (expression is! FunctionExpression) return false;

  // With a curly body.
  if (expression.body is! BlockFunctionBody) return false;

  // That isn't empty.
  var body = expression.body as BlockFunctionBody;
  return body.block.statements.isNotEmpty ||
      body.block.rightBracket.precedingComments != null;
}

/// Returns `true` if [expression] is a valid method invocation target for
/// an invocation that wraps a function literal argument.
bool _isValidWrappingTarget(Expression? expression) {
  // Allow bare function calls.
  if (expression == null) return true;

  // Allow property accesses.
  while (expression is PropertyAccess) {
    expression = expression.target;
  }

  if (expression is PrefixedIdentifier) return true;
  if (expression is SimpleIdentifier) return true;

  return false;
}

/// If [expression] can be formatted as a block, returns the token that opens
/// the block, such as a collection's bracket.
///
/// Block-formatted arguments can get special indentation to make them look
/// more statement-like.
Token? _blockToken(Expression expression) {
  if (expression is NamedExpression) {
    expression = expression.expression;
  }

  // TODO(rnystrom): Should we step into parenthesized expressions?

  if (expression is ListLiteral) return expression.leftBracket;
  if (expression is RecordLiteral) return expression.leftParenthesis;
  if (expression is SetOrMapLiteral) return expression.leftBracket;
  if (expression is SingleStringLiteral && expression.isMultiline) {
    return expression.beginToken;
  }

  // Not a collection literal.
  return null;
}

// TODO: Delete this once I'm sure there's nothing to harvest from it.
/*
class ArgumentListVisitor {
  final SourceVisitor _visitor;
  final List<Expression> _arguments;

  /// For each argument in the argument list, stores the `{` token for any
  /// block closure arguments that should not cause the argument list to split.
  ///
  /// For all other arguments, stores `null`. If no arguments should get block
  /// formatting, the list is empty.
  final List<Token?> _blockFunctions = [];

  ArgumentListVisitor(this._visitor, this._arguments) {
    var blockFunctions = _findBlockFunctions();
    if (blockFunctions != null) _blockFunctions.addAll(blockFunctions);
  }

  void visit() {
    for (var i = 0; i < _arguments.length; i++) {
      var blockToken = _blockFunctions.isEmpty ? null : _blockFunctions[i];
      if (blockToken != null) {
        _visitor.blockClosureInArgumentList(blockToken);
      }

      var argument = _arguments[i];
      _visitor.builder.split(nest: false, space: argument != _arguments.first);
      _visitor.visit(argument);
      _visitor.writeCommaAfter(argument);
    }
  }

  /// Look for a single contiguous range of block function [arguments] that
  /// should receive special formatting.
  ///
  /// If there are some, returns a list of `Token?` for each argument where the
  /// token is `null` if the corresponding argument is not a block closure and
  /// is the `{` token if it is.
  List<Token?>? _findBlockFunctions() {
    var tokens = <Token?>[];
    var hasBlocks = false;

    // Find the range of block function arguments, if any.
    for (var i = 0; i < _arguments.length; i++) {
      var argument = _arguments[i];
      var token = _blockFunctionToken(argument);
      tokens.add(token);

      // The functions must be one contiguous section.
      if (token != null) {
        if (hasBlocks) {
          // If we already found blocks, and this one is a block but the
          // previous one isn't, then the blocks are non-contiguous.
          if (i > 0 && tokens[i - 1] == null) return null;
        } else {
          hasBlocks = true;
        }
      }
    }

    if (!hasBlocks) return null;

    // TODO: Should this edge case apply?
    /*
    // Edge case: If all of the arguments are named, but they aren't all
    // functions, then don't handle the functions specially. A function with a
    // bunch of named arguments tends to look best when they are all lined up,
    // even the function ones (unless they are all functions).
    //
    // Prefers:
    //
    //     function(
    //         named: () {
    //           something();
    //         },
    //         another: argument);
    //
    // Over:
    //
    //     function(named: () {
    //       something();
    //     },
    //         another: argument);
    if (_isAllNamed(arguments) &&
        (functionsStart > 0 || functionsEnd < arguments.length)) {
      return null;
    }
    */

    // TODO: Should this edge case apply?
    /*
    // Edge case: If all of the function arguments are named and there are
    // other named arguments that are "=>" functions, then don't treat the
    // block-bodied functions specially. In a mixture of the two function
    // styles, it looks cleaner to treat them all like normal expressions so
    // that the named arguments line up.
    if (_isAllNamed(arguments.sublist(functionsStart, functionsEnd))) {
      bool isNamedArrow(Expression expression) {
        if (expression is! NamedExpression) return false;
        expression = expression.expression;

        return expression is FunctionExpression &&
            expression.body is ExpressionFunctionBody;
      }

      for (var i = 0; i < functionsStart; i++) {
        if (isNamedArrow(arguments[i])) return null;
      }

      for (var i = functionsEnd; i < arguments.length; i++) {
        if (isNamedArrow(arguments[i])) return null;
      }
    }
    */

    return tokens;
  }

  /*
  /// Returns `true` if every expression in [arguments] is named.
  static bool _isAllNamed(List<Expression> arguments) =>
      arguments.every((argument) => argument is NamedExpression);
  */

  /// Returns the `{` [Token] if [expression] is a [FunctionExpression] with a
  /// non-empty block body.
  Token? _blockFunctionToken(Expression expression) {
    if (expression is NamedExpression) expression = expression.expression;

    // TODO: Should any of these edge cases apply?
    /*
    // Allow functions wrapped in dotted method calls like "a.b.c(() { ... })".
    if (expression is MethodInvocation) {
      if (!_isValidWrappingTarget(expression.target)) return false;
      if (expression.argumentList.arguments.length != 1) return false;

      return _isBlockFunction(expression.argumentList.arguments.single);
    }

    if (expression is InstanceCreationExpression) {
      if (expression.argumentList.arguments.length != 1) return false;

      return _isBlockFunction(expression.argumentList.arguments.single);
    }

    // Allow immediately-invoked functions like "() { ... }()".
    if (expression is FunctionExpressionInvocation) {
      if (expression.argumentList.arguments.isNotEmpty) return false;

      expression = expression.function;
    }

    // Unwrap parenthesized expressions.
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }
    */

    // Must be a function.
    if (expression is! FunctionExpression) return null;

    // With a block body.
    var body = expression.body;
    if (body is! BlockFunctionBody) return null;

    // That isn't empty.
    if (body.block.statements.isEmpty &&
        body.block.rightBracket.precedingComments == null) {
      return null;
    }

    return body.block.leftBracket;
  }

  /*
  /// Returns `true` if [expression] is a valid method invocation target for
  /// an invocation that wraps a function literal argument.
  static bool _isValidWrappingTarget(Expression? expression) {
    // Allow bare function calls.
    if (expression == null) return true;

    // Allow property accesses.
    while (expression is PropertyAccess) {
      expression = expression.target;
    }

    if (expression is PrefixedIdentifier) return true;
    if (expression is SimpleIdentifier) return true;

    return false;
  }
  */
}

/// A range of arguments from a complete argument list.
///
/// One of these typically covers all of the arguments in an invocation. But,
/// when an argument list has block functions in the middle, the arguments
/// before and after the functions are treated as separate independent lists.
/// In that case, there will be two of these.
class ArgumentSublist {
  /// The full argument list from the AST.
  final List<Expression> _allArguments;

  /// If all positional arguments occur before all named arguments, then this
  /// contains the positional arguments, in order. Otherwise (there are no
  /// positional arguments or they are interleaved with named ones), this is
  /// empty.
  final List<Expression> _positional;

  /// The named arguments, in order. If there are any named arguments that occur
  /// before positional arguments, then all arguments are treated as named and
  /// end up in this list.
  final List<Expression> _named;

  /// Maps each block argument, excluding functions, to the first token for that
  /// argument.
  final Map<Expression, Token> _blocks;

  /// The number of leading block arguments, excluding functions.
  ///
  /// If all arguments are blocks, this counts them.
  final int _leadingBlocks;

  /// The number of trailing blocks arguments.
  ///
  /// If all arguments are blocks, this is zero.
  final int _trailingBlocks;

  /// The rule used to split the bodies of all block arguments.
  Rule get blockRule => _blockRule!;
  Rule? _blockRule;

  /// The most recent chunk that split before an argument.
  Chunk? get previousSplit => _previousSplit;
  Chunk? _previousSplit;

  factory ArgumentSublist(
      List<Expression> allArguments, List<Expression> arguments) {
    var blocks = <Expression, Token>{};
    for (var argument in arguments) {
      var bracket = _blockToken(argument);
      if (bracket != null) blocks[argument] = bracket;
    }

    // Count the leading arguments that are blocks.
    var leadingBlocks = 0;
    for (var argument in arguments) {
      if (!blocks.containsKey(argument)) break;
      leadingBlocks++;
    }

    // Count the trailing arguments that are blocks.
    var trailingBlocks = 0;
    if (leadingBlocks != arguments.length) {
      for (var argument in arguments.reversed) {
        if (!blocks.containsKey(argument)) break;
        trailingBlocks++;
      }
    }

    // Blocks must all be a prefix or suffix of the argument list (and not
    // both).
    if (leadingBlocks != blocks.length) leadingBlocks = 0;
    if (trailingBlocks != blocks.length) trailingBlocks = 0;

    // Ignore any blocks in the middle of the argument list.
    if (leadingBlocks == 0 && trailingBlocks == 0) blocks.clear();

    return ArgumentSublist._(blocks);
  }

  ArgumentSublist._(this._blocks);

  void visit(SourceVisitor visitor) {
    if (_blocks.isNotEmpty) {
      _blockRule = Rule(Cost.splitBlocks);
    }

    var rule = _visitPositional(visitor);
    _visitNamed(visitor, rule);
  }

  /// Writes the positional arguments, if any.
  PositionalRule? _visitPositional(SourceVisitor visitor) {
    if (_positional.isEmpty) return null;

    // Allow splitting after "(".
    // Only count the blocks in the positional rule.
    var leadingBlocks = math.min(_leadingBlocks, _positional.length);
    var trailingBlocks = math.max(_trailingBlocks - _named.length, 0);
    var rule = PositionalRule(_blockRule,
        argumentCount: _positional.length,
        leadingCollections: leadingBlocks,
        trailingCollections: trailingBlocks);
    _visitArguments(visitor, _positional, rule);

    return rule;
  }

  /// Writes the named arguments, if any.
  void _visitNamed(SourceVisitor visitor, PositionalRule? positionalRule) {
    if (_named.isEmpty) return;

    // Only count the blocks in the named rule.
    var leadingBlocks = math.max(_leadingBlocks - _positional.length, 0);
    var trailingBlocks = math.min(_trailingBlocks, _named.length);
    var namedRule = NamedRule(_blockRule, leadingBlocks, trailingBlocks);

    // Let the positional args force the named ones to split.
    if (positionalRule != null) {
      positionalRule.addNamedArgsConstraints(namedRule);
    }

    _visitArguments(visitor, _named, namedRule);
  }

  void _visitArguments(
      SourceVisitor visitor, List<Expression> arguments, ArgumentRule rule) {
    visitor.builder.startRule(rule);

    // Split before the first argument.
    _previousSplit =
        visitor.builder.split(space: arguments.first != _allArguments.first);
    rule.beforeArgument(_previousSplit);

    // Try to not split the positional arguments.
    if (arguments == _positional) {
      visitor.builder.startSpan(Cost.positionalArguments);
    }

    for (var argument in arguments) {
      _visitArgument(visitor, rule, argument);

      // Write the split.
      if (argument != arguments.last) {
        _previousSplit = visitor.split();
        rule.beforeArgument(_previousSplit);
      }
    }

    if (arguments == _positional) visitor.builder.endSpan();

    visitor.builder.endRule();
  }

  void _visitArgument(
      SourceVisitor visitor, ArgumentRule rule, Expression argument) {
    // If we're about to write a block argument, handle it specially.
    var argumentBlock = _blocks[argument];
    if (argumentBlock != null) {
      rule.disableSplitOnInnerRules();

      // Tell it to use the rule we've already created.
      visitor.beforeBlock(argumentBlock, blockRule, previousSplit);
    } else if (_allArguments.length > 1 ||
        _allArguments.first is RecordLiteral) {
      // Edge case: Only bump the nesting if there are multiple arguments. This
      // lets us avoid spurious indentation in cases like:
      //
      //     function(function(() {
      //       body;
      //     }));
      //
      // Do bump the nesting if the single argument is a record because records
      // are formatted like regular values when they appear in argument lists
      // even though they internally get block-like formatting.
      visitor.builder.startBlockArgumentNesting();
    } else if (argument is! NamedExpression) {
      // Edge case: Likewise, don't force the argument to split if there is
      // only a single positional one, like:
      //
      //     outer(inner(
      //         longArgument));
      rule.disableSplitOnInnerRules();
    }

    if (argument is NamedExpression) {
      visitor.visitNamedNode(argument.name.label.token, argument.name.colon,
          argument.expression, rule as NamedRule);
    } else {
      visitor.visit(argument);
    }

    if (argumentBlock != null) {
      rule.enableSplitOnInnerRules();
    } else if (_allArguments.length > 1 ||
        _allArguments.first is RecordLiteral) {
      visitor.builder.endBlockArgumentNesting();
    } else if (argument is! NamedExpression) {
      rule.enableSplitOnInnerRules();
    }

    // Write the following comma.
    if (argument.hasCommaAfter) {
      visitor.token(argument.endToken.next);
    }
  }
}
*/
