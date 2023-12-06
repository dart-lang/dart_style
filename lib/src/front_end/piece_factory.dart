// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/assign.dart';
import '../piece/block.dart';
import '../piece/clause.dart';
import '../piece/function.dart';
import '../piece/if.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/postfix.dart';
import '../piece/try.dart';
import '../piece/type.dart';
import 'adjacent_builder.dart';
import 'ast_node_visitor.dart';
import 'comment_writer.dart';
import 'delimited_list_builder.dart';
import 'piece_writer.dart';
import 'sequence_builder.dart';

/// Record type for a destructured binary operator-like syntactic construct.
typedef BinaryOperation = (AstNode left, Token operator, AstNode right);

/// Utility methods for creating pieces that share formatting logic across
/// multiple parts of the language.
///
/// Many AST nodes are structurally similar and receive similar formatting. For
/// example, imports and exports are mostly the same, with exports a subset of
/// imports. Likewise, assert statements are formatted like function calls and
/// argument lists.
///
/// This mixin defines functions that represent a general construct that is
/// formatted a certain way. The function builds up an appropriate set of
/// [Piece]s given the various AST subcomponents passed in as parameters. The
/// main [AstNodeVisitor] class then calls those for all of the AST nodes that
/// should receive that similar formatting.
///
/// These are all void functions because they generally push their result into
/// the [PieceWriter].
///
/// Naming these functions can be hard. For example, there isn't an obvious
/// word for "import or export directive" or "named thing with argument list".
/// To avoid that, we pick one concrete construct formatted by the function,
/// usually the most common, and name it after that, as in [createImport()].
mixin PieceFactory {
  PieceWriter get pieces;

  CommentWriter get comments;

  Piece nodePiece(AstNode node, {bool commaAfter = false});

  /// Creates a [ListPiece] for an argument list.
  Piece createArgumentList(
      Token leftBracket, Iterable<AstNode> elements, Token rightBracket) {
    return createList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: const ListStyle(allowBlockElement: true));
  }

  /// Creates a [BlockPiece] for a given bracket-delimited block or declaration
  /// body.
  ///
  /// If [forceSplit] is `true`, then the block will split even if empty. This
  /// is used, for example, with empty blocks in `if` statements followed by
  /// `else` clauses:
  ///
  /// ```
  /// if (condition) {
  /// } else {}
  /// ```
  Piece createBody(
      Token leftBracket, List<AstNode> contents, Token rightBracket,
      {bool forceSplit = false}) {
    var leftBracketPiece = tokenPiece(leftBracket);

    var sequence = SequenceBuilder(this);
    for (var node in contents) {
      sequence.visit(node);

      // If the node has a non-empty braced body, then require a blank line
      // between it and the next node.
      if (node.hasNonEmptyBody) sequence.addBlank();
    }

    // Place any comments before the "}" inside the block.
    sequence.addCommentsBefore(rightBracket);

    var rightBracketPiece = tokenPiece(rightBracket);

    return BlockPiece(leftBracketPiece, sequence.build(), rightBracketPiece,
        alwaysSplit: forceSplit || contents.isNotEmpty || sequence.mustSplit);
  }

  /// Creates a [BlockPiece] for a given [Block].
  ///
  /// If [forceSplit] is `true`, then the block will split even if empty. This
  /// is used, for example, with empty blocks in `if` statements followed by
  /// `else` clauses:
  ///
  /// ```
  /// if (condition) {
  /// } else {}
  /// ```
  Piece createBlock(Block block, {bool forceSplit = false}) {
    return createBody(block.leftBracket, block.statements, block.rightBracket,
        forceSplit: forceSplit);
  }

  /// Creates a piece for a `break` or `continue` statement.
  Piece createBreak(Token keyword, SimpleIdentifier? label, Token semicolon) {
    return buildPiece((b) {
      b.token(keyword);
      b.visit(label, spaceBefore: true);
      b.token(semicolon);
    });
  }

  /// Creates a [ListPiece] for a collection literal.
  Piece createCollection(Token? constKeyword, Token leftBracket,
      List<AstNode> elements, Token rightBracket,
      {TypeArgumentList? typeArguments, ListStyle style = const ListStyle()}) {
    return buildPiece((b) {
      b.modifier(constKeyword);
      b.visit(typeArguments);

      // TODO(tall): Support a line comment inside a collection literal as a
      // signal to preserve internal newlines. So if you have:
      //
      // ```
      // var list = [
      //   1, 2, 3, // comment
      //   4, 5, 6,
      // ];
      // ```
      //
      // The formatter will preserve the newline after element 3 and the lack of
      // them after the other elements.

      b.add(createList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: style,
      ));
    });
  }

  /// Visits the leading keyword and parenthesized expression at the beginning
  /// of an `if`, `while`, or `switch` expression or statement.
  Piece startControlFlow(Token keyword, Token leftParenthesis, Expression value,
      Token rightParenthesis) {
    // Attach the keyword to the `(`.
    return buildPiece((b) {
      b.token(keyword);
      b.space();
      b.token(leftParenthesis);
      b.visit(value);
      b.token(rightParenthesis);
    });
  }

  /// Creates metadata annotations for a directive.
  ///
  /// Always forces the annotations to be on a previous line.
  void createDirectiveMetadata(Directive directive) {
    // TODO(tall): Implement. See SourceVisitor._visitDirectiveMetadata().
    if (directive.metadata.isNotEmpty) throw UnimplementedError();
  }

  /// Creates a dotted or qualified identifier.
  Piece createDotted(NodeList<SimpleIdentifier> components) {
    return buildPiece((b) {
      for (var component in components) {
        // Write the preceding ".".
        if (component != components.first) {
          b.token(component.beginToken.previous!);
        }

        b.visit(component);
      }
    });
  }

  /// Creates a [Piece] for an enum constant.
  ///
  /// If the constant is in an enum declaration that also declares members, then
  /// [hasMembers] should be `true`, [semicolon] is the `;` token before the
  /// members (if any), and [isLastConstant] is `true` if [node] is the last
  /// constant before the members.
  Piece createEnumConstant(EnumConstantDeclaration node,
      {bool hasMembers = false,
      bool isLastConstant = false,
      Token? semicolon}) {
    return buildPiece((b) {
      b.token(node.name);
      if (node.arguments case var arguments?) {
        b.visit(arguments.typeArguments);
        b.visit(arguments.argumentList);
      }

      if (hasMembers) {
        if (!isLastConstant) {
          b.token(node.commaAfter);
        } else {
          // Discard the trailing comma if there is one since there is a
          // semicolon to use as the separator, but preserve any comments before
          // the discarded comma.
          b.commentsBefore(node.commaAfter);
          b.token(semicolon);
        }
      }
    });
  }

  /// Creates a function, method, getter, or setter declaration.
  ///
  /// If [modifierKeyword] is given, it should be the `static` or `abstract`
  /// modifier on a method declaration. If [operatorKeyword] is given, it
  /// should be the `operator` keyword on an operator declaration. If
  /// [propertyKeyword] is given, it should be the `get` or `set` keyword on a
  /// getter or setter declaration.
  Piece createFunction(
      {Token? externalKeyword,
      Token? modifierKeyword,
      AstNode? returnType,
      Token? operatorKeyword,
      Token? propertyKeyword,
      Token? name,
      TypeParameterList? typeParameters,
      FormalParameterList? parameters,
      required FunctionBody body}) {
    var builder = AdjacentBuilder(this);
    builder.modifier(externalKeyword);
    builder.modifier(modifierKeyword);

    Piece? returnTypePiece;
    if (returnType != null) {
      builder.visit(returnType);
      returnTypePiece = builder.build();
    }

    builder.modifier(operatorKeyword);
    builder.modifier(propertyKeyword);
    builder.token(name);
    builder.visit(typeParameters);
    builder.visit(parameters);
    var signature = builder.build();

    var bodyPiece = nodePiece(body);

    return FunctionPiece(returnTypePiece, signature,
        body: bodyPiece, spaceBeforeBody: body is! EmptyFunctionBody);
  }

  /// Creates a function type or function-typed formal.
  ///
  /// If creating a piece for a function-typed formal, then [parameter] is the
  /// formal parameter.
  Piece createFunctionType(
      TypeAnnotation? returnType,
      Token functionKeywordOrName,
      TypeParameterList? typeParameters,
      FormalParameterList parameters,
      Token? question,
      {FunctionTypedFormalParameter? parameter}) {
    var builder = AdjacentBuilder(this);

    if (parameter != null) startFormalParameter(parameter, builder);

    Piece? returnTypePiece;
    if (returnType != null) {
      builder.visit(returnType);
      returnTypePiece = builder.build();
    }

    builder.token(functionKeywordOrName);
    builder.visit(typeParameters);
    builder.visit(parameters);
    builder.token(question);

    return FunctionPiece(returnTypePiece, builder.build());
  }

  /// Creates a [TryPiece] for try statement.
  Piece createTry(TryStatement tryStatement) {
    var piece = TryPiece();

    var tryHeader = tokenPiece(tryStatement.tryKeyword);
    var tryBlock = createBlock(tryStatement.body);
    piece.add(tryHeader, tryBlock);

    for (var i = 0; i < tryStatement.catchClauses.length; i++) {
      var catchClause = tryStatement.catchClauses[i];

      var catchClauseHeader = buildPiece((b) {
        if (catchClause.onKeyword case var onKeyword?) {
          b.token(onKeyword, spaceAfter: true);
          b.visit(catchClause.exceptionType);
        }

        if (catchClause.onKeyword != null && catchClause.catchKeyword != null) {
          b.space();
        }

        if (catchClause.catchKeyword case var catchKeyword?) {
          b.token(catchKeyword);
          b.space();

          var parameters = DelimitedListBuilder(this);
          parameters.leftBracket(catchClause.leftParenthesis!);
          if (catchClause.exceptionParameter case var exceptionParameter?) {
            parameters.visit(exceptionParameter);
          }
          if (catchClause.stackTraceParameter case var stackTraceParameter?) {
            parameters.visit(stackTraceParameter);
          }
          parameters.rightBracket(catchClause.rightParenthesis!);
          b.add(parameters.build());
        }
      });

      // Edge case: When there's another catch/on/finally after this one, we
      // want to force the block to split even if it's empty.
      //
      // ```
      // try {
      //   ..
      // } on Foo {
      // } finally Bar {
      //   body;
      // }
      // ```
      var forceSplit = i < tryStatement.catchClauses.length - 1 ||
          tryStatement.finallyBlock != null;
      var catchClauseBody =
          createBlock(catchClause.body, forceSplit: forceSplit);
      piece.add(catchClauseHeader, catchClauseBody);
    }

    if (tryStatement.finallyBlock case var finallyBlock?) {
      var finallyHeader = tokenPiece(tryStatement.finallyKeyword!);
      var finallyBody = createBlock(finallyBlock);
      piece.add(finallyHeader, finallyBody);
    }

    return piece;
  }

  // TODO(tall): Generalize this to work with if elements too.
  /// Creates a piece for a chain of if-else-if... statements.
  Piece createIf(IfStatement ifStatement) {
    var piece = IfPiece();

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(Piece? previousElse, IfStatement node) {
      var condition = buildPiece((b) {
        if (previousElse != null) b.add(previousElse);
        b.add(startControlFlow(node.ifKeyword, node.leftParenthesis,
            node.expression, node.rightParenthesis));
      });

      // Edge case: When the then branch is a block and there is an else clause
      // after it, we want to force the block to split even if empty, like:
      //
      // ```
      // if (condition) {
      // } else {
      //   body;
      // }
      // ```
      var thenStatement = switch (node.thenStatement) {
        Block thenBlock when node.elseStatement != null =>
          createBlock(thenBlock, forceSplit: true),
        _ => nodePiece(node.thenStatement)
      };

      piece.add(condition, thenStatement, isBlock: node.thenStatement is Block);

      switch (node.elseStatement) {
        case IfStatement elseIf:
          // Hit an else-if, so flatten it into the chain with the `else`
          // becoming part of the next section's header.
          traverse(buildPiece((b) {
            b.token(node.elseKeyword);
            b.space();
          }), elseIf);

        case var elseStatement?:
          // Any other kind of else body ends the chain, with the header for
          // the last section just being the `else` keyword.
          var header = tokenPiece(node.elseKeyword!);
          var statement = nodePiece(elseStatement);
          piece.add(header, statement, isBlock: elseStatement is Block);
      }
    }

    traverse(null, ifStatement);
    return piece;
  }

  /// Creates an [ImportPiece] for an import or export directive.
  Piece createImport(NamespaceDirective directive, Token keyword,
      {Token? deferredKeyword, Token? asKeyword, SimpleIdentifier? prefix}) {
    var builder = AdjacentBuilder(this);
    createDirectiveMetadata(directive);
    builder.token(keyword);
    builder.space();
    builder.visit(directive.uri);

    if (directive.configurations.isNotEmpty) {
      var configurations = <Piece>[];
      for (var configuration in directive.configurations) {
        configurations.add(nodePiece(configuration));
      }

      builder.add(PostfixPiece(configurations));
    }

    if (asKeyword != null) {
      builder.add(PostfixPiece([
        buildPiece((b) {
          b.token(deferredKeyword, spaceAfter: true);
          b.token(asKeyword);
          b.space();
          b.visit(prefix!);
        })
      ]));
    }

    if (directive.combinators.isNotEmpty) {
      var combinators = <ClausePiece>[];
      for (var combinatorNode in directive.combinators) {
        var combinatorKeyword = tokenPiece(combinatorNode.keyword);

        switch (combinatorNode) {
          case HideCombinator(hiddenNames: var names):
          case ShowCombinator(shownNames: var names):
            var parts = <Piece>[];
            for (var name in names) {
              parts.add(tokenPiece(name.token, commaAfter: true));
            }

            var combinator = ClausePiece(combinatorKeyword, parts);
            combinators.add(combinator);
          default:
            throw StateError('Unknown combinator type $combinatorNode.');
        }
      }

      builder.add(ClausesPiece(combinators));
    }

    builder.token(directive.semicolon);
    return builder.build();
  }

  /// Creates a single infix operation.
  ///
  /// If [hanging] is `true` then the operator goes at the end of the first
  /// line, like `+`. Otherwise, it goes at the beginning of the second, like
  /// `as`.
  ///
  /// The [operator2] parameter may be passed if the "operator" is actually two
  /// separate tokens, as in `foo is! Bar`.
  Piece createInfix(AstNode left, Token operator, AstNode right,
      {bool hanging = false, Token? operator2}) {
    var leftPiece = buildPiece((b) {
      b.visit(left);
      if (hanging) {
        b.space();
        b.token(operator);
        b.token(operator2);
      }
    });

    var rightPiece = buildPiece((b) {
      if (!hanging) {
        b.token(operator);
        b.token(operator2);
        b.space();
      }

      b.visit(right);
    });

    return InfixPiece([leftPiece, rightPiece]);
  }

  /// Creates a chained infix operation: a binary operator expression, or
  /// binary pattern.
  ///
  /// In a tree of binary AST nodes, all operators at the same precedence are
  /// treated as a single chain of operators that either all split or none do.
  /// Operands within those (which may themselves be chains of higher
  /// precedence binary operators) are then formatted independently.
  ///
  /// [T] is the type of node being visited and [destructure] is a callback
  /// that takes one of those and yields the operands and operator. We need
  /// this since there's no interface shared by the various binary operator
  /// AST nodes.
  ///
  /// If [precedence] is given, then this only flattens binary nodes with that
  /// same precedence.
  Piece createInfixChain<T extends AstNode>(
      T node, BinaryOperation Function(T node) destructure,
      {int? precedence}) {
    var builder = AdjacentBuilder(this);
    var operands = <Piece>[];

    void traverse(AstNode e) {
      // If the node is one if our infix operators, then recurse into the
      // operands.
      if (e is T) {
        var (left, operator, right) = destructure(e);
        if (precedence == null || operator.type.precedence == precedence) {
          traverse(left);
          builder.space();
          builder.token(operator);
          operands.add(builder.build());
          traverse(right);
          return;
        }
      }

      // Otherwise, just write the node itself.
      builder.visit(e);
    }

    traverse(node);
    operands.add(builder.build());

    return InfixPiece(operands);
  }

  /// Creates a [ListPiece] for the given bracket-delimited set of elements.
  Piece createList(Iterable<AstNode> elements,
      {Token? leftBracket,
      Token? rightBracket,
      ListStyle style = const ListStyle()}) {
    var builder = DelimitedListBuilder(this, style);
    if (leftBracket != null) builder.leftBracket(leftBracket);
    elements.forEach(builder.visit);
    if (rightBracket != null) builder.rightBracket(rightBracket);
    return builder.build();
  }

  /// Creates a class, enum, extension, mixin, or mixin application class
  /// declaration.
  ///
  /// For all but a mixin application class, [body] should a record containing
  /// the bracket delimiters and the list of member declarations for the type's
  /// body.
  ///
  /// For mixin application classes, [body] is `null` and instead [equals],
  /// [superclass], and [semicolon] are provided.
  ///
  /// If the type is an extension, then [onType] is a record containing the
  /// `on` keyword and the on type.
  Piece createType(NodeList<Annotation> metadata, List<Token?> modifiers,
      Token keyword, Token? name,
      {TypeParameterList? typeParameters,
      Token? equals,
      NamedType? superclass,
      ExtendsClause? extendsClause,
      OnClause? onClause,
      WithClause? withClause,
      ImplementsClause? implementsClause,
      NativeClause? nativeClause,
      (Token, TypeAnnotation)? onType,
      ({Token leftBracket, List<AstNode> members, Token rightBracket})? body,
      Token? semicolon}) {
    if (metadata.isNotEmpty) throw UnimplementedError('Type metadata.');

    var header = buildPiece((b) {
      modifiers.forEach(b.modifier);
      b.token(keyword);
      b.token(name, spaceBefore: true);

      if (typeParameters != null) {
        b.visit(typeParameters);
      }

      // Mixin application classes have ` = Superclass` after the declaration
      // name.
      if (equals != null) {
        b.space();
        b.token(equals);
        b.space();
        b.visit(superclass!);
      }
    });

    var clauses = <ClausePiece>[];

    void typeClause(Token keyword, List<AstNode> types) {
      var keywordPiece = tokenPiece(keyword);

      var typePieces = <Piece>[];
      for (var type in types) {
        typePieces.add(nodePiece(type, commaAfter: true));
      }

      clauses.add(ClausePiece(keywordPiece, typePieces));
    }

    if (extendsClause != null) {
      typeClause(extendsClause.extendsKeyword, [extendsClause.superclass]);
    }

    if (onClause != null) {
      typeClause(onClause.onKeyword, onClause.superclassConstraints);
    }

    if (withClause != null) {
      typeClause(withClause.withKeyword, withClause.mixinTypes);
    }

    if (implementsClause != null) {
      typeClause(
          implementsClause.implementsKeyword, implementsClause.interfaces);
    }

    if (onType case (var onKeyword, var onType)?) {
      typeClause(onKeyword, [onType]);
    }

    if (nativeClause != null) {
      typeClause(nativeClause.nativeKeyword,
          [if (nativeClause.name case var name?) name]);
    }

    ClausesPiece? clausesPiece;
    if (clauses.isNotEmpty) {
      clausesPiece = ClausesPiece(clauses,
          allowLeadingClause: extendsClause != null || onClause != null);
    }

    Piece bodyPiece;
    if (body != null) {
      bodyPiece = createBody(body.leftBracket, body.members, body.rightBracket);
    } else {
      bodyPiece = tokenPiece(semicolon!);
    }

    return TypePiece(header, clausesPiece, bodyPiece, hasBody: body != null);
  }

  /// Creates a [ListPiece] for a type argument or type parameter list.
  Piece createTypeList(
      Token leftBracket, Iterable<AstNode> elements, Token rightBracket) {
    return createList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: const ListStyle(commas: Commas.nonTrailing, splitCost: 3));
  }

  /// Writes the parts of a formal parameter shared by all formal parameter
  /// types: metadata, `covariant`, etc.
  void startFormalParameter(
      FormalParameter parameter, AdjacentBuilder builder) {
    if (parameter.metadata.isNotEmpty) throw UnimplementedError();

    builder.modifier(parameter.requiredKeyword);
    builder.modifier(parameter.covariantKeyword);
  }

  /// Handles the `async`, `sync*`, or `async*` modifiers on a function body.
  void functionBodyModifiers(FunctionBody body, AdjacentBuilder builder) {
    // The `async` or `sync` keyword.
    builder.token(body.keyword);
    builder.token(body.star);
    if (body.keyword != null) builder.space();
  }

  /// Creates a [Piece] with "assignment-like" splitting.
  ///
  /// This is used, obviously, for assignments and variable declarations to
  /// handle splitting after the `=`, but is also used in any context where an
  /// expression follows something that it "defines" or "initializes":
  ///
  /// * Assignment
  /// * Variable declaration
  /// * Constructor initializer
  /// * Expression (`=>`) function body
  /// * Named argument or named record field (`:`)
  /// * Map entry (`:`)
  /// * For-in loop iterator (`in`)
  ///
  /// If [splitBeforeOperator] is `true`, then puts [operator] at the beginning
  /// of the next line when it splits. Otherwise, puts the operator at the end
  /// of the preceding line.
  Piece createAssignment(
      AstNode target, Token operator, Expression rightHandSide,
      {bool splitBeforeOperator = false,
      bool includeComma = false,
      bool spaceBeforeOperator = true}) {
    if (splitBeforeOperator) {
      var targetPiece = nodePiece(target);

      var initializer = buildPiece((b) {
        b.token(operator);
        b.space();
        b.visit(rightHandSide, commaAfter: includeComma);
      });

      return AssignPiece(targetPiece, initializer,
          isValueDelimited: rightHandSide.canBlockSplit);
    } else {
      var targetPiece = buildPiece((b) {
        b.visit(target);
        b.token(operator, spaceBefore: spaceBeforeOperator);
      });

      var initializer = nodePiece(rightHandSide, commaAfter: includeComma);

      return AssignPiece(targetPiece, initializer,
          isValueDelimited: rightHandSide.canBlockSplit);
    }
  }

  /// Invokes [buildCallback] with a new [AdjacentBuilder] and returns the
  /// built result.
  Piece buildPiece(void Function(AdjacentBuilder) buildCallback) {
    var builder = AdjacentBuilder(this);
    buildCallback(builder);
    return builder.build();
  }

  /// Creates a piece for only [token].
  ///
  /// If [lexeme] is given, uses that for the token's lexeme instead of its own.
  ///
  /// If [commaAfter] is `true`, will look for and write a comma following the
  /// token if there is one.
  Piece tokenPiece(Token token, {String? lexeme, bool commaAfter = false}) {
    return pieces.tokenPiece(token, lexeme: lexeme, commaAfter: commaAfter);
  }
}
