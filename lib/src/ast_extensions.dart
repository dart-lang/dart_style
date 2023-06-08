// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

extension AstNodeExtensions on AstNode {
  // TODO: Eventually, this should only be used by
  // `SourceVisitor.writeCommaAfter()` and can be inlined there.
  /// The comma token immediately following this if there is one, or `null`.
  Token? get commaAfter {
    var next = endToken.next!;
    if (next.type == TokenType.COMMA) return next;

    // TODO(sdk#38990): endToken doesn't include the "?" on a nullable
    // function-typed formal, so check for that case and handle it.
    if (next.type == TokenType.QUESTION && next.next!.type == TokenType.COMMA) {
      return next.next;
    }

    return null;
  }

  // TODO: Remove uses of this.
  /// Whether there is a comma token immediately following this.
  bool get hasCommaAfter => commaAfter != null;

  /// Whether this node is a statement or member with a braced body that isn't
  /// empty.
  ///
  /// Used to determine if a blank line should be inserted after the node.
  bool get hasNonEmptyBody {
    AstNode? body;
    var node = this;
    if (node is MethodDeclaration) {
      body = node.body;
    } else if (node is FunctionDeclarationStatement) {
      body = node.functionDeclaration.functionExpression.body;
    }

    return body is BlockFunctionBody && body.block.statements.isNotEmpty;
  }

  /// Whether this node is a bracket-delimited collection literal.
  bool get isCollectionLiteral =>
      this is ListLiteral || this is RecordLiteral || this is SetOrMapLiteral;

  bool get isControlFlowElement => this is IfElement || this is ForElement;

  // TODO: Better name.
  // TODO: Include switch expressions?
  /// Whether this node is an expression or pattern with an explicitly
  /// delimited collection-like body.
  bool get isDelimited {
    // TODO: Should we treat empty ones (without comments inside) differently?

    // TODO: Similar code in ExpressionListExtensions.blockArgument.
    var node = this;
    return switch (node) {
      ListLiteral(:var elements)
          when !elements.isEmptyBody(node.rightBracket) =>
        true,
      SetOrMapLiteral(:var elements)
          when !elements.isEmptyBody(node.rightBracket) =>
        true,
      RecordLiteral(:var fields)
          when !fields.isEmptyBody(node.rightParenthesis) =>
        true,
      ListPattern(:var elements)
          when !elements.isEmptyBody(node.rightBracket) =>
        true,
      MapPattern(:var elements) when !elements.isEmptyBody(node.rightBracket) =>
        true,
      ObjectPattern(:var fields)
          when !fields.isEmptyBody(node.rightParenthesis) =>
        true,
      RecordPattern(:var fields)
          when !fields.isEmptyBody(node.rightParenthesis) =>
        true,
      ConstantPattern()
        // Constant patterns whose body is a delimited expression are also
        // delimited.
        =>
        node.expression.isDelimited,
      _ => false,
    };
  }

  // TODO: Better name.
  // TODO: Can this be unified with `isDelimited`?
  /// Whether this node is an expression or pattern with a delimited
  /// collection-like body or a function call with an argument list.
  bool get isDelimitedOrCall {
    if (isDelimited) return true;

    var node = this;
    return switch (node) {
      // TODO: Only targetless ones?
      MethodInvocation(:var argumentList)
          when !argumentList.arguments
              .isEmptyBody(argumentList.rightParenthesis) =>
        true,

      // TODO: Test.
      InstanceCreationExpression(:var argumentList)
          when !argumentList.arguments
              .isEmptyBody(argumentList.rightParenthesis) =>
        true,
      _ => false,
    };
  }

  /// Whether this is immediately contained within an anonymous
  /// [FunctionExpression].
  bool get isFunctionExpressionBody =>
      parent is FunctionExpression && parent!.parent is! FunctionDeclaration;

  /// Whether [node] is a spread of a non-empty collection literal.
  bool get isSpreadCollection => spreadCollectionBracket != null;

  /// If this is a spread of a non-empty collection literal, then returns the
  /// token for the opening bracket of the collection, as in:
  ///
  ///     [ ...[a, list] ]
  ///     //   ^
  ///
  /// Otherwise, returns `null`.
  Token? get spreadCollectionBracket {
    var node = this;
    if (node is SpreadElement) {
      var expression = node.expression;
      if (expression is ListLiteral) {
        if (!expression.elements.isEmptyBody(expression.rightBracket)) {
          return expression.leftBracket;
        }
      } else if (expression is SetOrMapLiteral) {
        if (!expression.elements.isEmptyBody(expression.rightBracket)) {
          return expression.leftBracket;
        }
      }
    }

    return null;
  }
}

extension AstIterableExtensions on Iterable<AstNode> {
  /// Whether there is a comma token immediately following this.
  bool get hasCommaAfter => isNotEmpty && last.hasCommaAfter;

  /// Whether the collection literal or block containing these nodes and
  /// terminated by [rightBracket] is empty or not.
  ///
  /// An empty collection must have no elements or comments inside. Collections
  /// like that are treated specially because they cannot be split inside.
  bool isEmptyBody(Token rightBracket) =>
      isEmpty && rightBracket.precedingComments == null;
}

extension ExpressionExtensions on Expression {
  /// Given that `this` is a collection literal, or a [NamedExpression]
  /// containing a collection literal, returns the opening delimiter token for
  /// it.
  Token get collectionDelimiter {
    // Unwrap named arguments.
    var expression = this;
    if (expression is NamedExpression) {
      expression = expression.expression;
    }

    return switch (expression) {
      ListLiteral(:var leftBracket) ||
      SetOrMapLiteral(:var leftBracket) =>
        leftBracket,
      RecordLiteral(:var leftParenthesis) => leftParenthesis,
      MethodInvocation() => expression.argumentList.leftParenthesis,
      _ => throw ArgumentError.value(expression, 'expression')
    };
  }

  /// Whether this is an argument in an argument list with a trailing comma.
  bool get isTrailingCommaArgument {
    var parent = this.parent;
    if (parent is NamedExpression) parent = parent.parent;

    return parent is ArgumentList && parent.arguments.hasCommaAfter;
  }

  /// Whether this is a method invocation that looks like it might be a static
  /// method or constructor call without a `new` keyword.
  ///
  /// With optional `new`, we can no longer reliably identify constructor calls
  /// statically, but we still don't want to mix named constructor calls into
  /// a call chain like:
  ///
  ///     Iterable
  ///         .generate(...)
  ///         .toList();
  ///
  /// And instead prefer:
  ///
  ///     Iterable.generate(...)
  ///         .toList();
  ///
  /// So we try to identify these calls syntactically. The heuristic we use is
  /// that a target that's a capitalized name (possibly prefixed by "_") is
  /// assumed to be a class.
  ///
  /// This has the effect of also keeping static method calls with the class,
  /// but that tends to look pretty good too, and is certainly better than
  /// splitting up named constructors.
  bool get looksLikeStaticCall {
    var node = this;
    if (node is! MethodInvocation) return false;
    if (node.target == null) return false;

    // A prefixed unnamed constructor call:
    //
    //     prefix.Foo();
    if (node.target is SimpleIdentifier &&
        _looksLikeClassName(node.methodName.name)) {
      return true;
    }

    // A prefixed or unprefixed named constructor call:
    //
    //     Foo.named();
    //     prefix.Foo.named();
    var target = node.target;
    if (target is PrefixedIdentifier) target = target.identifier;

    return target is SimpleIdentifier && _looksLikeClassName(target.name);
  }

  /// Whether [name] appears to be a type name.
  ///
  /// Type names begin with a capital letter and contain at least one lowercase
  /// letter (so that we can distinguish them from SCREAMING_CAPS constants).
  static bool _looksLikeClassName(String name) {
    // Handle the weird lowercase corelib names.
    if (name == 'bool') return true;
    if (name == 'double') return true;
    if (name == 'int') return true;
    if (name == 'num') return true;

    // TODO(rnystrom): A simpler implementation is to test against the regex
    // "_?[A-Z].*?[a-z]". However, that currently has much worse performance on
    // AOT: https://github.com/dart-lang/sdk/issues/37785.
    const underscore = 95;
    const capitalA = 65;
    const capitalZ = 90;
    const lowerA = 97;
    const lowerZ = 122;

    var start = 0;
    var firstChar = name.codeUnitAt(start++);

    // It can be private.
    if (firstChar == underscore) {
      if (name.length == 1) return false;
      firstChar = name.codeUnitAt(start++);
    }

    // It must start with a capital letter.
    if (firstChar < capitalA || firstChar > capitalZ) return false;

    // And have at least one lowercase letter in it. Otherwise it could be a
    // SCREAMING_CAPS constant.
    for (var i = start; i < name.length; i++) {
      var char = name.codeUnitAt(i);
      if (char >= lowerA && char <= lowerZ) return true;
    }

    return false;
  }
}

extension CascadeExpressionExtensions on CascadeExpression {
  /// Whether a cascade should be allowed to be inline as opposed to moving the
  /// section to the next line.
  bool get allowInline {
    // Cascades with multiple sections are handled elsewhere and are never
    // inline.
    assert(cascadeSections.length == 1);

    // If the receiver is an expression that makes the cascade's very low
    // precedence confusing, force it to split. For example:
    //
    //     a ? b : c..d();
    //
    // Here, the cascade is applied to the result of the conditional, not "c".
    if (target is ConditionalExpression) return false;
    if (target is BinaryExpression) return false;
    if (target is PrefixExpression) return false;
    if (target is AwaitExpression) return false;

    return true;
  }
}

extension ExpressionListExtensions on List<Expression> {
  /// If [arguments] contains a single argument whose expression can receive
  /// block formatting, then returns it. Otherwise returns `null`.
  Expression? get blockArgument {
    var functions = <Expression>[];
    var collections = <Expression>[];
    var calls = <Expression>[];

    for (var argument in this) {
      // Unwrap named arguments so that we don't pick a positional block
      // argument if there are other named arguments of the same kind.
      var expression = argument;
      if (expression is NamedExpression) {
        expression = expression.expression;
      }

      switch (expression) {
        case FunctionExpression(body: BlockFunctionBody()):
          functions.add(argument);
        case ListLiteral(:var elements)
            when !elements.isEmptyBody(expression.rightBracket):
        case SetOrMapLiteral(:var elements)
            when !elements.isEmptyBody(expression.rightBracket):
        case RecordLiteral(:var fields)
            when !fields.isEmptyBody(expression.rightParenthesis):
        case SimpleStringLiteral(isMultiline: true):
        case StringInterpolation(isMultiline: true):
          collections.add(argument);
        case MethodInvocation(:var argumentList)
            when !argumentList.arguments
                .isEmptyBody(argumentList.rightParenthesis):
          calls.add(argument);
      }
    }

    Expression? blockArgument;
    if (functions.length == 1) {
      blockArgument = functions.first;
    } else if (functions.isEmpty && collections.length == 1) {
      blockArgument = collections.first;
    } else if (functions.isEmpty && collections.isEmpty && calls.length == 1) {
      blockArgument = calls.first;
    }

    // Don't allow named block arguments. When an argument list has named
    // arguments, it's more likely to have multiple arguments and it looks best
    // if the names are all clearly visible at the beginning of the lines.
    if (blockArgument is NamedExpression) return null;

    // Don't allow a named block argument with other named arguments, since it
    // makes it too easy to not see the names in the middle of a line, as in:
    //
    //    function(one: 1, two: [
    //      //             ^^^
    //      element
    //    ]);
    if (blockArgument is NamedExpression) {
      for (var argument in this) {
        if (argument != blockArgument && argument is NamedExpression) {
          return null;
        }
      }
    }

    return blockArgument;
  }
}
