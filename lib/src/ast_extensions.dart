// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import 'piece/list.dart';

extension AstNodeExtensions on AstNode {
  /// The first token at the beginning of this AST node, not including any
  /// tokens for leading doc comments.
  ///
  /// If [node] is an [AnnotatedNode], then [beginToken] includes the
  /// leading doc comment, which we want to handle separately. So, in that
  /// case, explicitly skip past the doc comment to the subsequent metadata
  /// (if there is any), or the beginning of the code.
  Token get firstNonCommentToken {
    return switch (this) {
      AnnotatedNode(metadata: [var annotation, ...]) => annotation.beginToken,
      AnnotatedNode(firstTokenAfterCommentAndMetadata: var token) => token,
      _ => beginToken
    };
  }

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
    } else if (node is FunctionDeclaration) {
      body = node.functionExpression.body;
    }

    return body is BlockFunctionBody && body.block.statements.isNotEmpty;
  }

  /// Whether this node is a bracket-delimited collection literal.
  bool get isCollectionLiteral =>
      this is ListLiteral || this is RecordLiteral || this is SetOrMapLiteral;

  bool get isControlFlowElement => this is IfElement || this is ForElement;

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
        if (expression.elements.canSplit(expression.rightBracket)) {
          return expression.leftBracket;
        }
      } else if (expression is SetOrMapLiteral) {
        if (expression.elements.canSplit(expression.rightBracket)) {
          return expression.leftBracket;
        }
      }
    }

    return null;
  }

  /// If this is a spread of a non-empty collection literal, then returns `this`
  /// as a [SpreadElement].
  ///
  /// Otherwise, returns `null`.
  SpreadElement? get spreadCollection {
    var node = this;
    if (node is! SpreadElement) return null;

    return switch (node.expression) {
      ListLiteral(:var elements, :var rightBracket) ||
      SetOrMapLiteral(:var elements, :var rightBracket)
          when elements.canSplit(rightBracket) =>
        node,
      _ => null,
    };
  }
}

extension AstIterableExtensions on Iterable<AstNode> {
  /// Whether there is a comma token immediately following this.
  bool get hasCommaAfter => isNotEmpty && last.hasCommaAfter;

  /// Whether the delimited construct containing these nodes and terminated by
  /// [rightBracket] can have a split inside it.
  ///
  /// We disallow splitting for entirely empty delimited constructs like `[]`,
  /// but allow a split if there are elements or comments inside.
  bool canSplit(Token rightBracket) =>
      isNotEmpty || rightBracket.precedingComments != null;

  /// Returns `true` if the collection containing these elements and terminated
  /// by [rightBracket] contains any line comments before, between, or after
  /// any elements.
  ///
  /// Comments within an element are ignored.
  bool containsLineComments([Token? rightBracket]) =>
      any((element) => element.beginToken.hasLineCommentBefore) ||
      (rightBracket?.hasLineCommentBefore ?? false);
}

extension ExpressionExtensions on Expression {
  /// Whether this expression is a non-empty delimited container for inner
  /// expressions that allows "block-like" formatting in some contexts. For
  /// example, in an assignment, a split in the assigned value is usually
  /// indented:
  ///
  ///     var variableName =
  ///         longValue;
  ///
  /// But if the initializer is block-like, we don't split at the `=`:
  ///
  ///     var variableName = [
  ///       element,
  ///     ];
  ///
  /// Likewise, in an argument list, block-like expressions can avoid splitting
  /// the surrounding argument list:
  ///
  ///     function([
  ///       element,
  ///     ]);
  ///
  /// Completely empty delimited constructs like `[]` and `foo()` don't allow
  /// splitting inside them, so are not considered block-like.
  bool get canBlockSplit => blockFormatType != BlockFormat.none;

  /// When this expression is in an argument list, what kind of block formatting
  /// category it belongs to.
  BlockFormat get blockFormatType {
    return switch (this) {
      // Unwrap named expressions to get the real expression inside.
      NamedExpression(:var expression) => expression.blockFormatType,

      // Allow the target of a single-section cascade to be block formatted.
      CascadeExpression(:var target, :var cascadeSections)
          when cascadeSections.length == 1 && target.canBlockSplit =>
        BlockFormat.invocation,

      // A function expression with a non-empty block body can block format.
      FunctionExpression(:var body)
          when body is BlockFunctionBody &&
              body.block.statements.canSplit(body.block.rightBracket) =>
        BlockFormat.function,

      // An immediately invoked function expression is formatted like a
      // function expression.
      FunctionExpressionInvocation(:FunctionExpression function)
          when function.blockFormatType == BlockFormat.function =>
        BlockFormat.function,

      // Non-empty collection literals can block split.
      ListLiteral(:var elements, :var rightBracket) ||
      SetOrMapLiteral(:var elements, :var rightBracket)
          when elements.canSplit(rightBracket) =>
        BlockFormat.collection,
      RecordLiteral(:var fields, :var rightParenthesis)
          when fields.canSplit(rightParenthesis) =>
        BlockFormat.collection,
      SwitchExpression(:var cases, :var rightBracket)
          when cases.canSplit(rightBracket) =>
        BlockFormat.collection,

      // Function calls can block split if their argument lists can.
      InstanceCreationExpression(:var argumentList) ||
      MethodInvocation(:var argumentList)
          when argumentList.arguments.canSplit(argumentList.rightParenthesis) =>
        BlockFormat.invocation,

      // Note: Using a separate case instead of `||` for this type because
      // Dart 3.0 reports an error that [argumentList] has a different type
      // here than in the previous two clauses.
      FunctionExpressionInvocation(:var argumentList)
          when argumentList.arguments.canSplit(argumentList.rightParenthesis) =>
        BlockFormat.invocation,

      // Multi-line strings can.
      StringInterpolation(isMultiline: true) => BlockFormat.collection,
      SimpleStringLiteral(isMultiline: true) => BlockFormat.collection,

      // Parenthesized expressions unwrap the inner expression.
      ParenthesizedExpression(:var expression) => expression.blockFormatType,
      _ => BlockFormat.none,
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
  /// Whether a cascade should be allowed to be inline with the target as
  /// opposed to moving the sections to the next line.
  bool get allowInline => switch (target) {
        // Cascades with multiple sections always split.
        _ when cascadeSections.length > 1 => false,

        // If the receiver is an expression that makes the cascade's very low
        // precedence confusing, force it to split. For example:
        //
        //     a ? b : c..d();
        //
        // Here, the cascade is applied to the result of the conditional, not
        // just "c".
        ConditionalExpression() => false,
        BinaryExpression() => false,
        PrefixExpression() => false,
        AwaitExpression() => false,

        // Otherwise, the target doesn't force a split.
        _ => true,
      };
}

extension AdjacentStringsExtensions on AdjacentStrings {
  /// Whether subsequent strings should be indented relative to the first
  /// string.
  ///
  /// We generally want to indent adjacent strings because it can be confusing
  /// otherwise when they appear in a list of expressions, like:
  ///
  ///     [
  ///       "one",
  ///       "two"
  ///       "three",
  ///       "four"
  ///     ]
  ///
  /// Especially when these strings are longer, it can be hard to tell that
  /// "three" is a continuation of the previous element.
  ///
  /// However, the indentation is distracting in places that don't suffer from
  /// this ambiguity:
  ///
  ///     var description =
  ///         "A very long description..."
  ///             "this extra indentation is unnecessary.");
  ///
  /// To balance these, we omit the indentation when an adjacent string
  /// expression is in a context where it's unlikely to be confusing.
  bool get indentStrings {
    bool hasOtherStringArgument(List<Expression> arguments) => arguments
        .any((argument) => argument != this && argument is StringLiteral);

    return switch (parent) {
      ArgumentList(:var arguments) => hasOtherStringArgument(arguments),

      // Treat asserts like argument lists.
      Assertion(:var condition, :var message) =>
        hasOtherStringArgument([condition, if (message != null) message]),

      // Don't add extra indentation in a variable initializer or assignment:
      //
      //     var variable =
      //         "no extra"
      //         "indent";
      VariableDeclaration() => false,
      AssignmentExpression(:var rightHandSide) when rightHandSide == this =>
        false,

      // Don't indent when following `:`.
      MapLiteralEntry(:var value) when value == this => false,
      NamedExpression() => false,

      // Don't indent when the body of a `=>` function.
      ExpressionFunctionBody() => false,
      _ => true,
    };
  }
}

extension PatternExtensions on DartPattern {
  /// Whether this expression is a non-empty delimited container for inner
  /// expressions that allows "block-like" formatting in some contexts.
  ///
  /// See [ExpressionExtensions.canBlockSplit].
  bool get canBlockSplit => switch (this) {
        ConstantPattern(:var expression) => expression.canBlockSplit,
        ListPattern(:var elements, :var rightBracket) =>
          elements.canSplit(rightBracket),
        MapPattern(:var elements, :var rightBracket) =>
          elements.canSplit(rightBracket),
        ObjectPattern(:var fields, :var rightParenthesis) ||
        RecordPattern(:var fields, :var rightParenthesis) =>
          fields.canSplit(rightParenthesis),
        _ => false,
      };
}

extension TokenExtensions on Token {
  /// Whether this token has a preceding comment that is a line comment.
  bool get hasLineCommentBefore {
    for (Token? comment = precedingComments;
        comment != null;
        comment = comment.next) {
      if (comment.type == TokenType.SINGLE_LINE_COMMENT) return true;
    }

    return false;
  }
}
