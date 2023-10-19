// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/assign.dart';
import '../piece/block.dart';
import '../piece/function.dart';
import '../piece/if.dart';
import '../piece/import.dart';
import '../piece/infix.dart';
import '../piece/piece.dart';
import '../piece/postfix.dart';
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
  void createBlock(Block block, {bool forceSplit = false}) {
    // Edge case: If the block is completely empty, output it as simple
    // unsplittable text unless it's forced to split.
    if (block.statements.isEmptyBody(block.rightBracket) && !forceSplit) {
      token(block.leftBracket);
      token(block.rightBracket);
      return;
    }

    token(block.leftBracket);
    var leftBracketPiece = writer.pop();
    writer.split();

    var sequence = SequenceBuilder(this);
    for (var node in block.statements) {
      sequence.add(node);
    }

    // Place any comments before the "}" inside the block.
    sequence.addCommentsBefore(block.rightBracket);

    token(block.rightBracket);
    var rightBracketPiece = writer.pop();

    writer.push(BlockPiece(
        leftBracketPiece, sequence.build(), rightBracketPiece,
        alwaysSplit: forceSplit || block.statements.isNotEmpty));
  }

  /// Creates a piece for a `break` or `continue` statement.
  void createBreak(Token keyword, SimpleIdentifier? label, Token semicolon) {
    token(keyword);
    if (label != null) {
      writer.space();
      visit(label);
    }
    token(semicolon);
  }

  /// Creates a [ListPiece] for a collection literal.
  void createCollection(TypedLiteral literal, Token leftBracket,
      List<AstNode> elements, Token rightBracket) {
    modifier(literal.constKeyword);
    visit(literal.typeArguments);

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

    createDelimited(leftBracket, elements, rightBracket);
  }

  /// Creates a [ListPiece] for the given bracket-delimited set of elements.
  void createDelimited(
      Token leftBracket, Iterable<AstNode> elements, Token rightBracket) {
    var builder = DelimitedListBuilder(this);
    builder.leftBracket(leftBracket);
    elements.forEach(builder.add);
    builder.rightBracket(rightBracket);
    writer.push(builder.build());
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
      returnTypePiece = writer.pop();
      writer.split();
    }

    token(functionKeywordOrName);
    visit(typeParameters);
    visit(parameters);
    token(question);

    // Allow splitting after the return type.
    if (returnTypePiece != null) {
      var parametersPiece = writer.pop();
      writer.push(FunctionTypePiece(returnTypePiece, parametersPiece));
    }
  }

  // TODO(tall): Generalize this to work with if elements too.
  /// Creates a piece for a chain of if-else-if... statements.
  void createIf(IfStatement ifStatement) {
    var piece = IfPiece();

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(IfStatement node) {
      token(node.ifKeyword);
      writer.space();
      token(node.leftParenthesis);
      visit(node.expression);
      token(node.rightParenthesis);
      var condition = writer.pop();
      writer.split();

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

      var thenStatement = writer.pop();
      writer.split();
      piece.add(condition, thenStatement, isBlock: node.thenStatement is Block);

      switch (node.elseStatement) {
        case IfStatement elseIf:
          // Hit an else-if, so flatten it into the chain with the `else`
          // becoming part of the next section's header.
          token(node.elseKeyword);
          writer.space();
          traverse(elseIf);

        case var elseStatement?:
          // Any other kind of else body ends the chain, with the header for
          // the last section just being the `else` keyword.
          token(node.elseKeyword);
          var header = writer.pop();
          writer.split();

          visit(elseStatement);
          var statement = writer.pop();
          writer.split();
          piece.add(header, statement, isBlock: elseStatement is Block);
      }
    }

    traverse(ifStatement);

    writer.push(piece);
  }

  /// Creates an [ImportPiece] for an import or export directive.
  void createImport(NamespaceDirective directive, Token keyword,
      {Token? deferredKeyword, Token? asKeyword, SimpleIdentifier? prefix}) {
    createDirectiveMetadata(directive);
    token(keyword);
    writer.space();
    visit(directive.uri);
    var directivePiece = writer.pop();

    Piece? configurationsPiece;
    if (directive.configurations.isNotEmpty) {
      var configurations = <Piece>[];
      for (var configuration in directive.configurations) {
        writer.split();
        visit(configuration);
        configurations.add(writer.pop());
      }

      configurationsPiece = PostfixPiece(configurations);
    }

    Piece? asClause;
    if (asKeyword != null) {
      writer.split();
      token(deferredKeyword, after: writer.space);
      token(asKeyword);
      writer.space();
      visit(prefix);
      asClause = PostfixPiece([writer.pop()]);
    }

    var combinators = <ImportCombinator>[];
    for (var combinatorNode in directive.combinators) {
      writer.split();
      token(combinatorNode.keyword);
      var combinator = ImportCombinator(writer.pop());
      combinators.add(combinator);

      switch (combinatorNode) {
        case HideCombinator(hiddenNames: var names):
        case ShowCombinator(shownNames: var names):
          for (var name in names) {
            writer.split();
            token(name.token);
            commaAfter(name);
            combinator.names.add(writer.pop());
          }
        default:
          throw StateError('Unknown combinator type $combinatorNode.');
      }
    }

    token(directive.semicolon);

    writer.push(ImportPiece(
        directivePiece, configurationsPiece, asClause, combinators));
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
    operands.add(writer.pop());

    if (hanging) {
      writer.space();
      token(operator);
      token(operator2);
      writer.split();
    } else {
      writer.split();
      token(operator);
      token(operator2);
      writer.space();
    }

    visit(right);
    operands.add(writer.pop());
    writer.push(InfixPiece(operands));
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
      if (e is! T) {
        visit(e);
        operands.add(writer.pop());
      } else {
        var (left, operator, right) = destructure(e);
        if (precedence != null && operator.type.precedence != precedence) {
          // Binary node, but a different precedence, so don't flatten.
          visit(e);
          operands.add(writer.pop());
        } else {
          traverse(left);

          writer.space();
          token(operator);

          writer.split();
          traverse(right);
        }
      }
    }

    traverse(node);

    writer.push(InfixPiece(operands));
  }

  /// Writes the parts of a formal parameter shared by all formal parameter
  /// types: metadata, `coviariant`, etc.
  void startFormalParameter(FormalParameter parameter) {
    if (parameter.metadata.isNotEmpty) throw UnimplementedError();

    modifier(parameter.requiredKeyword);
    if (parameter.covariantKeyword != null) throw UnimplementedError();
  }

  /// Creates a [Piece] for some code followed by an `=` and an expression in
  /// any place where an `=` appears:
  ///
  /// * Assignment
  /// * Variable declaration
  /// * Constructor initializer
  ///
  /// This is also used for map literal entries and named arguments which are
  /// also sort of like bindings. In that case, [operator] is the `:`.
  ///
  /// This method assumes the code to the left of the `=` or `:` has already
  /// been visited.
  void finishAssignment(Token operator, Expression rightHandSide) {
    if (operator.type == TokenType.EQ) writer.space();
    token(operator);
    var target = writer.pop();
    writer.split();

    visit(rightHandSide);

    var initializer = writer.pop();
    writer.push(AssignPiece(target, initializer,
        isValueDelimited: rightHandSide.isDelimited));
  }

  /// Writes an optional modifier that precedes other code.
  void modifier(Token? keyword) {
    token(keyword, after: writer.space);
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
    writeLexeme(token.lexeme);
    if (after != null) after();
  }

  /// Writes the raw [lexeme] to the current text piece.
  void writeLexeme(String lexeme) {
    // TODO(tall): Preserve selection.
    writer.write(lexeme);
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
      writeLexeme(',');
    }
  }
}
