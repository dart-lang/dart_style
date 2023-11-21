// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/adjacent.dart';
import '../piece/assign.dart';
import '../piece/block.dart';
import '../piece/clause.dart';
import '../piece/function.dart';
import '../piece/if.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/postfix.dart';
import '../piece/type.dart';
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
mixin PieceFactory implements CommentWriter {
  void visit(AstNode? node, {void Function()? before, void Function()? after});

  /// Creates a [ListPiece] for an argument list.
  void createArgumentList(
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
  void createBody(Token leftBracket, List<AstNode> contents, Token rightBracket,
      {bool forceSplit = false}) {
    token(leftBracket);
    var leftBracketPiece = pieces.split();

    var sequence = SequenceBuilder(this);
    for (var node in contents) {
      sequence.visit(node);

      // If the node has a non-empty braced body, then require a blank line
      // between it and the next node.
      if (node.hasNonEmptyBody) sequence.addBlank();
    }

    // Place any comments before the "}" inside the block.
    sequence.addCommentsBefore(rightBracket);

    token(rightBracket);
    var rightBracketPiece = pieces.take();

    pieces.give(BlockPiece(
        leftBracketPiece, sequence.build(), rightBracketPiece,
        alwaysSplit: forceSplit || contents.isNotEmpty));
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
  void createBlock(Block block, {bool forceSplit = false}) {
    createBody(block.leftBracket, block.statements, block.rightBracket,
        forceSplit: forceSplit);
  }

  /// Creates a piece for a `break` or `continue` statement.
  void createBreak(Token keyword, SimpleIdentifier? label, Token semicolon) {
    token(keyword);
    if (label != null) {
      space();
      visit(label);
    }
    token(semicolon);
  }

  /// Creates a [ListPiece] for a collection literal.
  void createCollection(Token? constKeyword, Token leftBracket,
      List<AstNode> elements, Token rightBracket,
      {TypeArgumentList? typeArguments, ListStyle style = const ListStyle()}) {
    modifier(constKeyword);
    visit(typeArguments);

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

    createList(
      leftBracket: leftBracket,
      elements,
      rightBracket: rightBracket,
      style: style,
    );
  }

  /// Visits the leading keyword and parenthesized expression at the beginning
  /// of an `if`, `while`, or `switch` expression or statement.
  void startControlFlow(Token keyword, Token leftParenthesis, Expression value,
      Token rightParenthesis) {
    // Attach the keyword to the `(`.
    token(keyword);
    space();
    token(leftParenthesis);
    visit(value);
    token(rightParenthesis);
  }

  /// Creates metadata annotations for a directive.
  ///
  /// Always forces the annotations to be on a previous line.
  void createDirectiveMetadata(Directive directive) {
    // TODO(tall): Implement. See SourceVisitor._visitDirectiveMetadata().
    if (directive.metadata.isNotEmpty) throw UnimplementedError();
  }

  /// Creates a dotted or qualified identifier.
  void createDotted(NodeList<SimpleIdentifier> components) {
    for (var component in components) {
      // Write the preceding ".".
      if (component != components.first) {
        token(component.beginToken.previous);
      }

      visit(component);
    }
  }

  /// Creates a function, method, getter, or setter declaration.
  ///
  /// If [modifierKeyword] is given, it should be the `static` or `abstract`
  /// modifier on a method declaration. If [operatorKeyword] is given, it
  /// should be the `operator` keyword on an operator declaration. If
  /// [propertyKeyword] is given, it should be the `get` or `set` keyword on a
  /// getter or setter declaration.
  void createFunction(
      {Token? externalKeyword,
      Token? modifierKeyword,
      AstNode? returnType,
      Token? operatorKeyword,
      Token? propertyKeyword,
      required Token name,
      TypeParameterList? typeParameters,
      FormalParameterList? parameters,
      required FunctionBody body}) {
    modifier(externalKeyword);
    modifier(modifierKeyword);

    Piece? returnTypePiece;
    if (returnType != null) {
      visit(returnType);
      returnTypePiece = pieces.split();
    }

    modifier(operatorKeyword);
    modifier(propertyKeyword);
    token(name);

    finishFunction(returnTypePiece, typeParameters, parameters, body);
  }

  /// Creates a function type or function-typed formal.
  void createFunctionType(
      TypeAnnotation? returnType,
      Token? functionKeywordOrName,
      TypeParameterList? typeParameters,
      FormalParameterList parameters,
      Token? question) {
    Piece? returnTypePiece;
    if (returnType != null) {
      visit(returnType);
      returnTypePiece = pieces.split();
    }

    token(functionKeywordOrName);
    visit(typeParameters);
    visit(parameters);
    token(question);
    var parametersPiece = pieces.take();

    pieces.give(FunctionPiece(returnTypePiece, parametersPiece));
  }

  // TODO(tall): Generalize this to work with if elements too.
  /// Creates a piece for a chain of if-else-if... statements.
  void createIf(IfStatement ifStatement) {
    var piece = IfPiece();

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(IfStatement node) {
      startControlFlow(node.ifKeyword, node.leftParenthesis, node.expression,
          node.rightParenthesis);
      var condition = pieces.split();

      // Edge case: When the then branch is a block and there is an else clause
      // after it, we want to force the block to split even if empty, like:
      //
      // ```
      // if (condition) {
      // } else {
      //   body;
      // }
      // ```
      if (node.thenStatement case Block thenBlock
          when node.elseStatement != null) {
        createBlock(thenBlock, forceSplit: true);
      } else {
        visit(node.thenStatement);
      }

      var thenStatement = pieces.split();
      piece.add(condition, thenStatement, isBlock: node.thenStatement is Block);

      switch (node.elseStatement) {
        case IfStatement elseIf:
          // Hit an else-if, so flatten it into the chain with the `else`
          // becoming part of the next section's header.
          token(node.elseKeyword);
          space();
          traverse(elseIf);

        case var elseStatement?:
          // Any other kind of else body ends the chain, with the header for
          // the last section just being the `else` keyword.
          token(node.elseKeyword);
          var header = pieces.split();

          visit(elseStatement);
          var statement = pieces.take();
          piece.add(header, statement, isBlock: elseStatement is Block);
      }
    }

    traverse(ifStatement);

    pieces.give(piece);
  }

  /// Creates an [ImportPiece] for an import or export directive.
  void createImport(NamespaceDirective directive, Token keyword,
      {Token? deferredKeyword, Token? asKeyword, SimpleIdentifier? prefix}) {
    createDirectiveMetadata(directive);
    token(keyword);
    space();
    visit(directive.uri);
    var importPieces = [pieces.take()];

    if (directive.configurations.isNotEmpty) {
      var configurations = <Piece>[];
      for (var configuration in directive.configurations) {
        pieces.split();
        visit(configuration);
        configurations.add(pieces.take());
      }

      importPieces.add(PostfixPiece(configurations));
    }

    if (asKeyword != null) {
      pieces.split();
      token(deferredKeyword, after: space);
      token(asKeyword);
      space();
      visit(prefix);
      importPieces.add(PostfixPiece([pieces.take()]));
    }

    if (directive.combinators.isNotEmpty) {
      var combinators = <ClausePiece>[];
      for (var combinatorNode in directive.combinators) {
        pieces.split();
        token(combinatorNode.keyword);
        var combinatorKeyword = pieces.split();

        switch (combinatorNode) {
          case HideCombinator(hiddenNames: var names):
          case ShowCombinator(shownNames: var names):
            var parts = <Piece>[];
            for (var name in names) {
              pieces.split();
              token(name.token);
              commaAfter(name);
              parts.add(pieces.take());
            }

            var combinator = ClausePiece(combinatorKeyword, parts);
            combinators.add(combinator);
          default:
            throw StateError('Unknown combinator type $combinatorNode.');
        }
      }

      importPieces.add(ClausesPiece(combinators));
    }

    token(directive.semicolon);

    pieces.give(AdjacentPiece(importPieces));
  }

  /// Creates a single infix operation.
  ///
  /// If [hanging] is `true` then the operator goes at the end of the first
  /// line, like `+`. Otherwise, it goes at the beginning of the second, like
  /// `as`.
  ///
  /// The [operator2] parameter may be passed if the "operator" is actually two
  /// separate tokens, as in `foo is! Bar`.
  void createInfix(AstNode left, Token operator, AstNode right,
      {bool hanging = false, Token? operator2}) {
    var operands = <Piece>[];

    visit(left);

    if (hanging) {
      space();
      token(operator);
      token(operator2);
      operands.add(pieces.split());
    } else {
      operands.add(pieces.split());
      token(operator);
      token(operator2);
      space();
    }

    visit(right);
    operands.add(pieces.take());
    pieces.give(InfixPiece(operands));
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
  void createInfixChain<T extends AstNode>(
      T node, BinaryOperation Function(T node) destructure,
      {int? precedence}) {
    var operands = <Piece>[];

    void traverse(AstNode e) {
      // If the node is one if our infix operators, then recurse into the
      // operands.
      if (e is T) {
        var (left, operator, right) = destructure(e);
        if (precedence == null || operator.type.precedence == precedence) {
          traverse(left);
          space();
          token(operator);
          pieces.split();
          traverse(right);
          return;
        }
      }

      // Otherwise, just write the node itself.
      visit(e);
      operands.add(pieces.take());
    }

    traverse(node);

    pieces.give(InfixPiece(operands));
  }

  /// Creates a [ListPiece] for the given bracket-delimited set of elements.
  void createList(Iterable<AstNode> elements,
      {Token? leftBracket,
      Token? rightBracket,
      ListStyle style = const ListStyle()}) {
    var builder = DelimitedListBuilder(this, style);
    if (leftBracket != null) builder.leftBracket(leftBracket);
    elements.forEach(builder.visit);
    if (rightBracket != null) builder.rightBracket(rightBracket);
    pieces.give(builder.build());
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
  void createType(NodeList<Annotation> metadata, List<Token?> modifiers,
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

    modifiers.forEach(modifier);
    token(keyword);
    token(name, before: space);
    visit(typeParameters);

    // Mixin application classes have ` = Superclass` after the declaration
    // name.
    if (equals != null) {
      space();
      token(equals);
      space();
      visit(superclass);
    }

    var header = pieces.split();

    var clauses = <ClausePiece>[];

    void typeClause(Token keyword, List<AstNode> types) {
      token(keyword);
      var keywordPiece = pieces.split();

      var typePieces = <Piece>[];
      for (var type in types) {
        visit(type);
        commaAfter(type);
        typePieces.add(pieces.split());
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

    ClausesPiece? clausesPiece;
    if (clauses.isNotEmpty) {
      clausesPiece = ClausesPiece(clauses,
          allowLeadingClause: extendsClause != null || onClause != null);
    }

    visit(nativeClause);
    space();

    if (body != null) {
      createBody(body.leftBracket, body.members, body.rightBracket);
    } else {
      token(semicolon);
    }
    var bodyPiece = pieces.take();

    pieces.give(
        TypePiece(header, clausesPiece, bodyPiece, hasBody: body != null));
  }

  /// Creates a [ListPiece] for a type argument or type parameter list.
  void createTypeList(
      Token leftBracket, Iterable<AstNode> elements, Token rightBracket) {
    return createList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: const ListStyle(commas: Commas.nonTrailing, splitCost: 3));
  }

  /// Writes the parts of a formal parameter shared by all formal parameter
  /// types: metadata, `covariant`, etc.
  void startFormalParameter(FormalParameter parameter) {
    if (parameter.metadata.isNotEmpty) throw UnimplementedError();

    modifier(parameter.requiredKeyword);
    modifier(parameter.covariantKeyword);
  }

  /// Handles the `async`, `sync*`, or `async*` modifiers on a function body.
  void functionBodyModifiers(FunctionBody body) {
    // The `async` or `sync` keyword.
    token(body.keyword);
    token(body.star);
    if (body.keyword != null) space();
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
  /// This method assumes the code to the left of the operator has already
  /// been visited.
  ///
  /// If [splitBeforeOperator] is `true`, then puts [operator] at the beginning
  /// of the next line when it splits. Otherwise, puts the operator at the end
  /// of the preceding line.
  void finishAssignment(Token operator, Expression rightHandSide,
      {bool splitBeforeOperator = false}) {
    Piece target;
    if (splitBeforeOperator) {
      target = pieces.split();
      token(operator);
      space();
    } else {
      if (operator.type == TokenType.EQ) space();
      token(operator);
      target = pieces.split();
    }

    visit(rightHandSide);

    var initializer = pieces.take();
    pieces.give(AssignPiece(target, initializer,
        isValueDelimited: rightHandSide.canBlockSplit));
  }

  /// Finishes writing a named function declaration or anonymous function
  /// expression after the return type (if any) and name (if any) has been
  /// written.
  void finishFunction(Piece? returnType, TypeParameterList? typeParameters,
      FormalParameterList? parameters, FunctionBody body) {
    visit(typeParameters);
    visit(parameters);

    Piece parametersPiece;
    Piece? bodyPiece;
    if (body is EmptyFunctionBody) {
      // If the body is just `;`, then don't allow a space or split before the
      // semicolon by making it part of the parameters piece.
      token(body.semicolon);
      parametersPiece = pieces.split();
    } else {
      parametersPiece = pieces.split();
      visit(body);
      bodyPiece = pieces.take();
    }

    pieces.give(FunctionPiece(returnType, parametersPiece, bodyPiece));
  }

  /// Writes an optional modifier that precedes other code.
  void modifier(Token? keyword) {
    token(keyword, after: space);
  }

  /// Write a single space.
  void space() {
    pieces.writeSpace();
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// Does nothing if [token] is `null`. If [before] is given, it will be
  /// executed before the token is outout. Likewise, [after] will be called
  /// after the token is output.
  void token(Token? token, {void Function()? before, void Function()? after}) {
    if (token == null) return;

    writeCommentsBefore(token);

    if (before != null) before();
    pieces.writeToken(token);
    if (after != null) after();
  }

  /// Writes a comma after [node], if there is one.
  void commaAfter(AstNode node, {bool trailing = false}) {
    var nextToken = node.endToken.next!;
    if (nextToken.lexeme == ',') {
      token(nextToken);
    } else if (trailing) {
      // If there isn't a comma there, it must be a place where a trailing
      // comma can appear, so synthesize it. During formatting, we will decide
      // whether to include it.
      pieces.writeText(',');
    }
  }
}
