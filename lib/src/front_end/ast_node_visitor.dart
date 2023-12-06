// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../ast_extensions.dart';
import '../constants.dart';
import '../dart_formatter.dart';
import '../piece/adjacent.dart';
import '../piece/assign.dart';
import '../piece/block.dart';
import '../piece/chain.dart';
import '../piece/for.dart';
import '../piece/if.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/variable.dart';
import '../source_code.dart';
import 'adjacent_builder.dart';
import 'comment_writer.dart';
import 'delimited_list_builder.dart';
import 'piece_factory.dart';
import 'piece_writer.dart';
import 'sequence_builder.dart';

/// Visits every token of the AST and produces a tree of [Piece]s that
/// corresponds to it and contains every token and comment in the original
/// source.
///
/// To avoid this class becoming a monolith, functionality is divided into a
/// couple of mixins, one for each area of functionality. This class then
/// contains only shared state and the visitor methods for the AST.
class AstNodeVisitor extends ThrowingAstVisitor<Piece> with PieceFactory {
  @override
  final PieceWriter pieces;

  @override
  final CommentWriter comments;

  /// Create a new visitor that will be called to visit the code in [source].
  factory AstNodeVisitor(
      DartFormatter formatter, LineInfo lineInfo, SourceCode source) {
    var comments = CommentWriter(lineInfo);
    var pieces = PieceWriter(formatter, source, comments);
    return AstNodeVisitor._(pieces, comments);
  }

  AstNodeVisitor._(this.pieces, this.comments);

  /// Visits [node] and returns the formatted result.
  ///
  /// Returns a [SourceCode] containing the resulting formatted source and
  /// updated selection, if any.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  SourceCode run(AstNode node) {
    // Always treat the code being formatted as contained in a sequence, even
    // if we aren't formatting an entire compilation unit. That way, comments
    // before and after the node are handled properly.
    var sequence = SequenceBuilder(this);

    if (node is CompilationUnit) {
      if (node.scriptTag case var scriptTag?) {
        sequence.visit(scriptTag);
        sequence.addBlank();
      }

      // Put a blank line between the library tag and the other directives.
      Iterable<Directive> directives = node.directives;
      if (directives.isNotEmpty && directives.first is LibraryDirective) {
        sequence.visit(directives.first);
        sequence.addBlank();
        directives = directives.skip(1);
      }

      for (var directive in directives) {
        sequence.visit(directive);
      }

      for (var declaration in node.declarations) {
        var hasBody = declaration is ClassDeclaration ||
            declaration is EnumDeclaration ||
            declaration is ExtensionDeclaration;

        // Add a blank line before types with bodies.
        if (hasBody) sequence.addBlank();

        sequence.visit(declaration);

        // Add a blank line after type or function declarations with bodies.
        if (hasBody || declaration.hasNonEmptyBody) sequence.addBlank();
      }
    } else {
      // Just formatting a single statement.
      sequence.visit(node);
    }

    // Write any comments at the end of the code.
    sequence.addCommentsBefore(node.endToken.next!);

    // Finish writing and return the complete result.
    return pieces.finish(sequence.build());
  }

  @override
  Piece visitAdjacentStrings(AdjacentStrings node) {
    throw UnimplementedError();
  }

  @override
  Piece visitAnnotation(Annotation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitArgumentList(ArgumentList node) {
    return createArgumentList(
        node.leftParenthesis, node.arguments, node.rightParenthesis);
  }

  @override
  Piece visitAsExpression(AsExpression node) {
    return createInfix(node.expression, node.asOperator, node.type);
  }

  @override
  Piece visitAssertInitializer(AssertInitializer node) {
    throw UnimplementedError();
  }

  @override
  Piece visitAssertStatement(AssertStatement node) {
    return buildPiece((b) {
      b.token(node.assertKeyword);
      b.add(createArgumentList(
          node.leftParenthesis,
          [
            node.condition,
            if (node.message case var message?) message,
          ],
          node.rightParenthesis));
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitAssignedVariablePattern(AssignedVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitAssignmentExpression(AssignmentExpression node) {
    return createAssignment(
        node.leftHandSide, node.operator, node.rightHandSide);
  }

  @override
  Piece visitAwaitExpression(AwaitExpression node) {
    return buildPiece((b) {
      b.token(node.awaitKeyword);
      b.space();
      b.visit(node.expression);
    });
  }

  @override
  Piece visitBinaryExpression(BinaryExpression node) {
    return createInfixChain<BinaryExpression>(
        node,
        precedence: node.operator.type.precedence,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  Piece visitBlock(Block node) {
    return createBlock(node);
  }

  @override
  Piece visitBlockFunctionBody(BlockFunctionBody node) {
    return buildPiece((b) {
      functionBodyModifiers(node, b);
      b.visit(node.block);
    });
  }

  @override
  Piece visitBooleanLiteral(BooleanLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitBreakStatement(BreakStatement node) {
    return createBreak(node.breakKeyword, node.label, node.semicolon);
  }

  @override
  Piece visitCascadeExpression(CascadeExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitCastPattern(CastPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitCatchClause(CatchClause node) {
    throw UnsupportedError('This node is handled by visitTryStatement().');
  }

  @override
  Piece visitCatchClauseParameter(CatchClauseParameter node) {
    return tokenPiece(node.name);
  }

  @override
  Piece visitClassDeclaration(ClassDeclaration node) {
    return createType(
        node.metadata,
        [
          node.abstractKeyword,
          node.baseKeyword,
          node.interfaceKeyword,
          node.finalKeyword,
          node.sealedKeyword,
          node.mixinKeyword,
        ],
        node.classKeyword,
        node.name,
        typeParameters: node.typeParameters,
        extendsClause: node.extendsClause,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
        nativeClause: node.nativeClause,
        body: (
          leftBracket: node.leftBracket,
          members: node.members,
          rightBracket: node.rightBracket
        ));
  }

  @override
  Piece visitClassTypeAlias(ClassTypeAlias node) {
    return createType(
        node.metadata,
        [
          node.abstractKeyword,
          node.baseKeyword,
          node.interfaceKeyword,
          node.finalKeyword,
          node.sealedKeyword,
          node.mixinKeyword,
        ],
        node.typedefKeyword,
        node.name,
        equals: node.equals,
        superclass: node.superclass,
        typeParameters: node.typeParameters,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
        semicolon: node.semicolon);
  }

  @override
  Piece visitComment(Comment node) {
    throw UnsupportedError('Comments should be handled elsewhere.');
  }

  @override
  Piece visitCommentReference(CommentReference node) {
    throw UnsupportedError('Comments should be handled elsewhere.');
  }

  @override
  Piece visitCompilationUnit(CompilationUnit node) {
    throw UnsupportedError(
        'CompilationUnit should be handled directly by format().');
  }

  @override
  Piece visitConditionalExpression(ConditionalExpression node) {
    var condition = nodePiece(node.condition);

    var thenPiece = buildPiece((b) {
      b.token(node.question);
      b.space();
      b.visit(node.thenExpression);
    });

    var elsePiece = buildPiece((b) {
      b.token(node.colon);
      b.space();
      b.visit(node.elseExpression);
    });

    var piece = InfixPiece([condition, thenPiece, elsePiece]);

    // If conditional expressions are directly nested, force them all to split,
    // both parents and children.
    if (node.parent is ConditionalExpression ||
        node.thenExpression is ConditionalExpression ||
        node.elseExpression is ConditionalExpression) {
      piece.pin(State.split);
    }

    return piece;
  }

  @override
  Piece visitConfiguration(Configuration node) {
    return buildPiece((b) {
      b.token(node.ifKeyword);
      b.space();
      b.token(node.leftParenthesis);

      if (node.equalToken case var equals?) {
        b.add(createInfix(node.name, equals, node.value!, hanging: true));
      } else {
        b.visit(node.name);
      }

      b.token(node.rightParenthesis);
      b.space();
      b.visit(node.uri);
    });
  }

  @override
  Piece visitConstantPattern(ConstantPattern node) {
    if (node.constKeyword != null) throw UnimplementedError();
    return nodePiece(node.expression);
  }

  @override
  Piece visitConstructorDeclaration(ConstructorDeclaration node) {
    throw UnimplementedError();
  }

  @override
  Piece visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    throw UnimplementedError();
  }

  @override
  Piece visitConstructorName(ConstructorName node) {
    throw UnsupportedError(
        'This node is handled by visitInstanceCreationExpression().');
  }

  @override
  Piece visitContinueStatement(ContinueStatement node) {
    return createBreak(node.continueKeyword, node.label, node.semicolon);
  }

  @override
  Piece visitDeclaredIdentifier(DeclaredIdentifier node) {
    return buildPiece((b) {
      b.modifier(node.keyword);
      b.visit(node.type, spaceAfter: true);
      b.token(node.name);
    });
  }

  @override
  Piece visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitDefaultFormalParameter(DefaultFormalParameter node) {
    if (node.separator case var separator?) {
      return createAssignment(node.parameter, separator, node.defaultValue!,
          spaceBeforeOperator: separator.type == TokenType.EQ);
    } else {
      return nodePiece(node.parameter);
    }
  }

  @override
  Piece visitDoStatement(DoStatement node) {
    return buildPiece((b) {
      b.token(node.doKeyword);
      b.space();
      b.visit(node.body);
      b.space();
      b.token(node.whileKeyword);
      b.space();
      b.token(node.leftParenthesis);
      b.visit(node.condition);
      b.token(node.rightParenthesis);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitDottedName(DottedName node) {
    return createDotted(node.components);
  }

  @override
  Piece visitDoubleLiteral(DoubleLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitEmptyFunctionBody(EmptyFunctionBody node) {
    return tokenPiece(node.semicolon);
  }

  @override
  Piece visitEmptyStatement(EmptyStatement node) {
    return tokenPiece(node.semicolon);
  }

  @override
  Piece visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    return createEnumConstant(node);
  }

  @override
  Piece visitEnumDeclaration(EnumDeclaration node) {
    if (node.metadata.isNotEmpty) throw UnimplementedError();

    var header = buildPiece((b) {
      b.token(node.enumKeyword);
      b.space();
      b.token(node.name);
      b.visit(node.typeParameters);
    });

    if (node.members.isEmpty) {
      // If there are no members, format the constants like a delimited list.
      // This keeps the enum declaration on one line if it fits.
      var builder = DelimitedListBuilder(
          this,
          const ListStyle(
              spaceWhenUnsplit: true, splitListIfBeforeSplits: true));
      builder.leftBracket(node.leftBracket, preceding: header);
      node.constants.forEach(builder.visit);
      builder.rightBracket(semicolon: node.semicolon, node.rightBracket);
      return builder.build();
    } else {
      var builder = AdjacentBuilder(this);
      builder.add(header);
      builder.space();

      // If there are members, format it like a block where each constant and
      // member is on its own line.
      var leftBracketPiece = tokenPiece(node.leftBracket);

      var sequence = SequenceBuilder(this);
      for (var constant in node.constants) {
        sequence.addCommentsBefore(constant.firstNonCommentToken);
        sequence.add(createEnumConstant(constant,
            hasMembers: true,
            isLastConstant: constant == node.constants.last,
            semicolon: node.semicolon));
      }

      // Insert a blank line between the constants and members.
      sequence.addBlank();

      for (var node in node.members) {
        sequence.visit(node);

        // If the node has a non-empty braced body, then require a blank line
        // between it and the next node.
        if (node.hasNonEmptyBody) sequence.addBlank();
      }

      // Place any comments before the "}" inside the block.
      sequence.addCommentsBefore(node.rightBracket);

      var rightBracketPiece = tokenPiece(node.rightBracket);

      builder.add(
          BlockPiece(leftBracketPiece, sequence.build(), rightBracketPiece));
      return builder.build();
    }
  }

  @override
  Piece visitExportDirective(ExportDirective node) {
    return createImport(node, node.exportKeyword);
  }

  @override
  Piece visitExpressionFunctionBody(ExpressionFunctionBody node) {
    return buildPiece((b) {
      var operatorPiece = buildPiece((b) {
        functionBodyModifiers(node, b);
        b.token(node.functionDefinition);
      });

      var expression = nodePiece(node.expression);

      b.add(AssignPiece(operatorPiece, expression,
          isValueDelimited: node.expression.canBlockSplit));
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitExpressionStatement(ExpressionStatement node) {
    return buildPiece((b) {
      b.visit(node.expression);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitExtendsClause(ExtendsClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  Piece visitExtensionDeclaration(ExtensionDeclaration node) {
    return createType(node.metadata, const [], node.extensionKeyword, node.name,
        typeParameters: node.typeParameters,
        onType: (node.onKeyword, node.extendedType),
        body: (
          leftBracket: node.leftBracket,
          members: node.members,
          rightBracket: node.rightBracket
        ));
  }

  @override
  Piece visitFieldDeclaration(FieldDeclaration node) {
    return buildPiece((b) {
      b.modifier(node.externalKeyword);
      b.modifier(node.staticKeyword);
      b.modifier(node.abstractKeyword);
      b.modifier(node.covariantKeyword);
      b.visit(node.fields);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitFieldFormalParameter(FieldFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  Piece visitFormalParameterList(FormalParameterList node) {
    // Find the first non-mandatory parameter (if there are any).
    var firstOptional =
        node.parameters.indexWhere((p) => p is DefaultFormalParameter);

    // If all parameters are optional, put the `[` or `{` right after `(`.
    var builder = DelimitedListBuilder(this);
    if (node.parameters.isNotEmpty && firstOptional == 0) {
      builder.leftBracket(node.leftParenthesis, delimiter: node.leftDelimiter);
    } else {
      builder.leftBracket(node.leftParenthesis);
    }

    for (var i = 0; i < node.parameters.length; i++) {
      // If this is the first optional parameter, put the delimiter before it.
      if (firstOptional > 0 && i == firstOptional) {
        builder.leftDelimiter(node.leftDelimiter!);
      }

      builder.visit(node.parameters[i]);
    }

    builder.rightBracket(node.rightParenthesis, delimiter: node.rightDelimiter);
    return builder.build();
  }

  @override
  Piece visitForElement(ForElement node) {
    throw UnimplementedError();
  }

  @override
  Piece visitForStatement(ForStatement node) {
    var forKeyword = buildPiece((b) {
      b.modifier(node.awaitKeyword);
      b.token(node.forKeyword);
    });

    Piece forPartsPiece;
    switch (node.forLoopParts) {
      // Edge case: A totally empty for loop is formatted just as `(;;)` with
      // no splits or spaces anywhere.
      case ForPartsWithExpression(
                initialization: null,
                leftSeparator: Token(precedingComments: null),
                condition: null,
                rightSeparator: Token(precedingComments: null),
                updaters: NodeList(isEmpty: true),
              ) &&
              var forParts
          when node.rightParenthesis.precedingComments == null:
        forPartsPiece = buildPiece((b) {
          b.token(node.leftParenthesis);
          b.token(forParts.leftSeparator);
          b.token(forParts.rightSeparator);
          b.token(node.rightParenthesis);
        });

      case ForParts forParts &&
            ForPartsWithDeclarations(variables: AstNode? initializer):
      case ForParts forParts &&
            ForPartsWithExpression(initialization: AstNode? initializer):
        // In a C-style for loop, treat the for loop parts like an argument list
        // where each clause is a separate argument. This means that when they
        // split, they split like:
        //
        // ```
        // for (
        //   initializerClause;
        //   conditionClause;
        //   incrementClause
        // ) {
        //   body;
        // }
        // ```
        var partsList =
            DelimitedListBuilder(this, const ListStyle(commas: Commas.none));
        partsList.leftBracket(node.leftParenthesis);

        // The initializer clause.
        if (initializer != null) {
          partsList.addCommentsBefore(initializer.beginToken);
          partsList.add(buildPiece((b) {
            b.visit(initializer);
            b.token(forParts.leftSeparator);
          }));
        } else {
          // No initializer, so look at the comments before `;`.
          partsList.addCommentsBefore(forParts.leftSeparator);
          partsList.add(tokenPiece(forParts.leftSeparator));
        }

        // The condition clause.
        if (forParts.condition case var conditionExpression?) {
          partsList.addCommentsBefore(conditionExpression.beginToken);
          partsList.add(buildPiece((b) {
            b.visit(conditionExpression);
            b.token(forParts.rightSeparator);
          }));
        } else {
          partsList.addCommentsBefore(forParts.rightSeparator);
          partsList.add(tokenPiece(forParts.rightSeparator));
        }

        // The update clauses.
        if (forParts.updaters.isNotEmpty) {
          partsList.addCommentsBefore(forParts.updaters.first.beginToken);
          partsList.add(createList(forParts.updaters,
              style: const ListStyle(commas: Commas.nonTrailing)));
        }

        partsList.rightBracket(node.rightParenthesis);
        forPartsPiece = partsList.build();

      case ForPartsWithPattern():
        throw UnimplementedError();

      case ForEachParts forEachParts &&
            ForEachPartsWithDeclaration(loopVariable: AstNode variable):
      case ForEachParts forEachParts &&
            ForEachPartsWithIdentifier(identifier: AstNode variable):
        // If a for-in loop, treat the for parts like an assignment, so they
        // split like:
        //
        // ```
        // for (var variable in [
        //   initializer,
        // ]) {
        //   body;
        // }
        // ```
        forPartsPiece = buildPiece((b) {
          b.token(node.leftParenthesis);
          b.add(createAssignment(
              variable, forEachParts.inKeyword, forEachParts.iterable,
              splitBeforeOperator: true));
          b.token(node.rightParenthesis);
        });

      case ForEachPartsWithPattern():
        throw UnimplementedError();
    }

    var body = nodePiece(node.body);

    return ForPiece(forKeyword, forPartsPiece, body,
        hasBlockBody: node.body is Block);
  }

  @override
  Piece visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitForPartsWithExpression(ForPartsWithExpression node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitForPartsWithPattern(ForPartsWithPattern node) {
    throw UnsupportedError('This node is handled by visitForStatement().');
  }

  @override
  Piece visitFunctionDeclaration(FunctionDeclaration node) {
    return createFunction(
        externalKeyword: node.externalKeyword,
        returnType: node.returnType,
        propertyKeyword: node.propertyKeyword,
        name: node.name,
        typeParameters: node.functionExpression.typeParameters,
        parameters: node.functionExpression.parameters,
        body: node.functionExpression.body);
  }

  @override
  Piece visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    return nodePiece(node.functionDeclaration);
  }

  @override
  Piece visitFunctionExpression(FunctionExpression node) {
    return createFunction(
        typeParameters: node.typeParameters,
        parameters: node.parameters,
        body: node.body);
  }

  @override
  Piece visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitFunctionReference(FunctionReference node) {
    throw UnimplementedError();
  }

  @override
  Piece visitFunctionTypeAlias(FunctionTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  Piece visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    return createFunctionType(
        parameter: node,
        node.returnType,
        node.name,
        node.typeParameters,
        node.parameters,
        node.question);
  }

  @override
  Piece visitGenericFunctionType(GenericFunctionType node) {
    return createFunctionType(node.returnType, node.functionKeyword,
        node.typeParameters, node.parameters, node.question);
  }

  @override
  Piece visitGenericTypeAlias(GenericTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  Piece visitHideCombinator(HideCombinator node) {
    throw UnsupportedError('Combinators are handled by createImport().');
  }

  @override
  Piece visitIfElement(IfElement node) {
    throw UnimplementedError();
  }

  @override
  Piece visitIfStatement(IfStatement node) {
    return createIf(node);
  }

  @override
  Piece visitImplementsClause(ImplementsClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  Piece visitImportDirective(ImportDirective node) {
    return createImport(node, node.importKeyword,
        deferredKeyword: node.deferredKeyword,
        asKeyword: node.asKeyword,
        prefix: node.prefix);
  }

  @override
  Piece visitIndexExpression(IndexExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitInstanceCreationExpression(InstanceCreationExpression node) {
    var builder = AdjacentBuilder(this);
    builder.token(node.keyword, spaceAfter: true);

    // If there is an import prefix and/or constructor name, then allow
    // splitting before the `.`. This doesn't look good, but is consistent with
    // constructor calls that don't have `new` or `const`. We allow splitting
    // in the latter because there is no way to distinguish syntactically
    // between a named constructor call and any other kind of method call or
    // property access.
    var operations = <Piece>[];

    var constructor = node.constructorName;
    if (constructor.type.importPrefix case var importPrefix?) {
      builder.token(importPrefix.name);
      operations.add(builder.build());
      builder.token(importPrefix.period);
    }

    // The type being constructed.
    var type = constructor.type;
    builder.token(type.name2);
    builder.visit(type.typeArguments);

    // If this is a named constructor call, the name.
    if (constructor.name case var name?) {
      operations.add(builder.build());
      builder.token(constructor.period);
      builder.visit(name);
    }

    builder.visit(node.argumentList);
    operations.add(builder.build());

    if (operations.length > 1) {
      return ChainPiece(operations);
    } else {
      return operations.first;
    }
  }

  @override
  Piece visitIntegerLiteral(IntegerLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitInterpolationExpression(InterpolationExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitInterpolationString(InterpolationString node) {
    throw UnimplementedError();
  }

  @override
  Piece visitIsExpression(IsExpression node) {
    return createInfix(
        node.expression,
        node.isOperator,
        operator2: node.notOperator,
        node.type);
  }

  @override
  Piece visitLabel(Label node) {
    return buildPiece((b) {
      b.visit(node.label);
      b.token(node.colon);
    });
  }

  @override
  Piece visitLabeledStatement(LabeledStatement node) {
    var sequence = SequenceBuilder(this);
    for (var label in node.labels) {
      sequence.visit(label);
    }

    sequence.visit(node.statement);
    return sequence.build();
  }

  @override
  Piece visitLibraryDirective(LibraryDirective node) {
    return buildPiece((b) {
      createDirectiveMetadata(node);
      b.token(node.libraryKeyword);
      b.visit(node.name2, spaceBefore: true);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitLibraryIdentifier(LibraryIdentifier node) {
    return createDotted(node.components);
  }

  @override
  Piece visitListLiteral(ListLiteral node) {
    return createCollection(
      node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  Piece visitListPattern(ListPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitLogicalAndPattern(LogicalAndPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitLogicalOrPattern(LogicalOrPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitMapLiteralEntry(MapLiteralEntry node) {
    return createAssignment(node.key, node.separator, node.value,
        spaceBeforeOperator: false);
  }

  @override
  Piece visitMapPattern(MapPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitMapPatternEntry(MapPatternEntry node) {
    throw UnimplementedError();
  }

  @override
  Piece visitMethodDeclaration(MethodDeclaration node) {
    return createFunction(
        externalKeyword: node.externalKeyword,
        modifierKeyword: node.modifierKeyword,
        returnType: node.returnType,
        operatorKeyword: node.operatorKeyword,
        propertyKeyword: node.propertyKeyword,
        name: node.name,
        typeParameters: node.typeParameters,
        parameters: node.parameters,
        body: node.body);
  }

  @override
  Piece visitMethodInvocation(MethodInvocation node) {
    return buildPiece((b) {
      // TODO(tall): Support splitting at `.` or `?.`. Right now we just format
      // it inline so that we can use method calls in other tests.
      b.visit(node.target);
      b.token(node.operator);
      b.visit(node.methodName);
      b.visit(node.typeArguments);
      b.visit(node.argumentList);
    });
  }

  @override
  Piece visitMixinDeclaration(MixinDeclaration node) {
    return createType(
        node.metadata, [node.baseKeyword], node.mixinKeyword, node.name,
        typeParameters: node.typeParameters,
        onClause: node.onClause,
        implementsClause: node.implementsClause,
        body: (
          leftBracket: node.leftBracket,
          members: node.members,
          rightBracket: node.rightBracket
        ));
  }

  @override
  Piece visitNamedExpression(NamedExpression node) {
    return createAssignment(node.name.label, node.name.colon, node.expression,
        spaceBeforeOperator: false);
  }

  @override
  Piece visitNamedType(NamedType node) {
    return buildPiece((b) {
      b.token(node.importPrefix?.name);
      b.token(node.importPrefix?.period);
      b.token(node.name2);
      b.visit(node.typeArguments);
      b.token(node.question);
    });
  }

  @override
  Piece visitNativeClause(NativeClause node) {
    return buildPiece((b) {
      b.token(node.nativeKeyword);
      b.visit(node.name, spaceBefore: true);
    });
  }

  @override
  Piece visitNativeFunctionBody(NativeFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  Piece visitNullAssertPattern(NullAssertPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitNullCheckPattern(NullCheckPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitNullLiteral(NullLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitObjectPattern(ObjectPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitOnClause(OnClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  Piece visitParenthesizedExpression(ParenthesizedExpression node) {
    return buildPiece((b) {
      b.token(node.leftParenthesis);
      b.visit(node.expression);
      b.token(node.rightParenthesis);
    });
  }

  @override
  Piece visitParenthesizedPattern(ParenthesizedPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPartDirective(PartDirective node) {
    return buildPiece((b) {
      createDirectiveMetadata(node);
      b.token(node.partKeyword);
      b.space();
      b.visit(node.uri);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitPartOfDirective(PartOfDirective node) {
    return buildPiece((b) {
      createDirectiveMetadata(node);

      b.token(node.partKeyword);
      b.space();
      b.token(node.ofKeyword);
      b.space();

      // Part-of may have either a name or a URI. Only one of these will be
      // non-null. We visit both since visit() ignores null.
      b.visit(node.libraryName);
      b.visit(node.uri);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitPatternAssignment(PatternAssignment node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPatternField(PatternField node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPostfixExpression(PostfixExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPrefixedIdentifier(PrefixedIdentifier node) {
    throw UnimplementedError();
  }

  @override
  Piece visitPrefixExpression(PrefixExpression node) {
    return buildPiece((b) {
      b.token(node.operator);

      // Edge case: put a space after "-" if the operand is "-" or "--" so that
      // we don't merge the operator tokens.
      if (node.operand
          case PrefixExpression(operator: Token(lexeme: '-' || '--'))) {
        b.space();
      }

      b.visit(node.operand);
    });
  }

  @override
  Piece visitPropertyAccess(PropertyAccess node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRecordLiteral(RecordLiteral node) {
    ListStyle style;
    if (node.fields.length == 1 && node.fields[0] is! NamedExpression) {
      // Single-element records always have a trailing comma, unless the single
      // element is a named field.
      style = const ListStyle(commas: Commas.alwaysTrailing);
    } else {
      style = const ListStyle(commas: Commas.trailing);
    }

    return createCollection(
      node.constKeyword,
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
      style: style,
    );
  }

  @override
  Piece visitRecordPattern(RecordPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRelationalPattern(RelationalPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRethrowExpression(RethrowExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitRestPatternElement(RestPatternElement node) {
    throw UnimplementedError();
  }

  @override
  Piece visitReturnStatement(ReturnStatement node) {
    return buildPiece((b) {
      b.token(node.returnKeyword);
      b.visit(node.expression, spaceBefore: true);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it.
    return tokenPiece(node.scriptTag, lexeme: node.scriptTag.lexeme.trim());
  }

  @override
  Piece visitSetOrMapLiteral(SetOrMapLiteral node) {
    return createCollection(
      node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  Piece visitShowCombinator(ShowCombinator node) {
    throw UnsupportedError('Combinators are handled by createImport().');
  }

  @override
  Piece visitSimpleFormalParameter(SimpleFormalParameter node) {
    var builder = AdjacentBuilder(this);
    startFormalParameter(node, builder);
    builder.modifier(node.keyword);

    if ((node.type, node.name) case (var _?, var name?)) {
      // Have both a type and name, so allow splitting after the type.
      builder.visit(node.type);
      var typePiece = builder.build();
      var namePiece = tokenPiece(name);
      return VariablePiece(typePiece, [namePiece], hasType: true);
    } else {
      // Don't have both a type and name, so just write whichever one we have.
      builder.visit(node.type);
      builder.token(node.name);
      return builder.build();
    }
  }

  @override
  Piece visitSimpleIdentifier(SimpleIdentifier node) {
    return tokenPiece(node.token);
  }

  @override
  Piece visitSimpleStringLiteral(SimpleStringLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitSpreadElement(SpreadElement node) {
    throw UnimplementedError();
  }

  @override
  Piece visitStringInterpolation(StringInterpolation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  Piece visitSuperExpression(SuperExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitSuperFormalParameter(SuperFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  Piece visitSwitchExpression(SwitchExpression node) {
    var value = startControlFlow(node.switchKeyword, node.leftParenthesis,
        node.expression, node.rightParenthesis);

    var list = DelimitedListBuilder(this,
        const ListStyle(spaceWhenUnsplit: true, splitListIfBeforeSplits: true));
    list.leftBracket(node.leftBracket, preceding: value);

    for (var member in node.cases) {
      list.visit(member);
    }

    list.rightBracket(node.rightBracket);
    return list.build();
  }

  @override
  Piece visitSwitchExpressionCase(SwitchExpressionCase node) {
    if (node.guardedPattern.whenClause != null) throw UnimplementedError();

    return createAssignment(
        node.guardedPattern.pattern, node.arrow, node.expression);
  }

  @override
  Piece visitSwitchStatement(SwitchStatement node) {
    var leftBracket = buildPiece((b) {
      b.add(startControlFlow(node.switchKeyword, node.leftParenthesis,
          node.expression, node.rightParenthesis));
      b.space();
      b.token(node.leftBracket);
    });

    var sequence = SequenceBuilder(this);
    for (var member in node.members) {
      for (var label in member.labels) {
        sequence.visit(label);
      }

      sequence.addCommentsBefore(member.keyword);

      var casePiece = buildPiece((b) {
        b.token(member.keyword);

        if (member is SwitchCase) {
          b.space();
          b.visit(member.expression);
        } else if (member is SwitchPatternCase) {
          if (member.guardedPattern.whenClause != null) {
            throw UnimplementedError();
          }

          b.space();
          b.visit(member.guardedPattern.pattern);
        } else {
          assert(member is SwitchDefault);
          // Nothing to do.
        }

        b.token(member.colon);
      });

      // Don't allow any blank lines between the `case` line and the first
      // statement in the case (or the next case if this case has no body).
      sequence.add(casePiece, indent: Indent.none, allowBlankAfter: false);

      for (var statement in member.statements) {
        sequence.visit(statement, indent: Indent.block);
      }
    }

    // Place any comments before the "}" inside the sequence.
    sequence.addCommentsBefore(node.rightBracket);
    var rightBracketPiece = tokenPiece(node.rightBracket);

    return BlockPiece(leftBracket, sequence.build(), rightBracketPiece,
        alwaysSplit: node.members.isNotEmpty || sequence.mustSplit);
  }

  @override
  Piece visitSymbolLiteral(SymbolLiteral node) {
    return buildPiece((b) {
      b.token(node.poundSign);
      var components = node.components;
      for (var component in components) {
        // The '.' separator.
        if (component != components.first) {
          b.token(component.previous!);
        }

        b.token(component);
      }
    });
  }

  @override
  Piece visitThisExpression(ThisExpression node) {
    return tokenPiece(node.thisKeyword);
  }

  @override
  Piece visitThrowExpression(ThrowExpression node) {
    throw UnimplementedError();
  }

  @override
  Piece visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    return buildPiece((b) {
      b.modifier(node.externalKeyword);
      b.visit(node.variables);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitTryStatement(TryStatement node) {
    return createTry(node);
  }

  @override
  Piece visitTypeArgumentList(TypeArgumentList node) {
    return createTypeList(node.leftBracket, node.arguments, node.rightBracket);
  }

  @override
  Piece visitTypeParameter(TypeParameter node) {
    return buildPiece((b) {
      b.token(node.name);
      if (node.bound case var bound?) {
        b.space();
        b.token(node.extendsKeyword);
        b.space();
        b.visit(bound);
      }
    });
  }

  @override
  Piece visitTypeParameterList(TypeParameterList node) {
    return createTypeList(
        node.leftBracket, node.typeParameters, node.rightBracket);
  }

  @override
  Piece visitVariableDeclaration(VariableDeclaration node) {
    throw UnsupportedError('This is handled by visitVariableDeclarationList()');
  }

  @override
  Piece visitVariableDeclarationList(VariableDeclarationList node) {
    // TODO(tall): Format metadata.
    if (node.metadata.isNotEmpty) throw UnimplementedError();

    var header = buildPiece((b) {
      b.modifier(node.lateKeyword);
      b.modifier(node.keyword);

      // TODO(tall): Test how splits inside the type annotation (like in a type
      // argument list or a function type's parameter list) affect the
      // indentation and splitting of the surrounding variable declaration.
      b.visit(node.type);
    });

    var variables = <Piece>[];
    for (var variable in node.variables) {
      if ((variable.equals, variable.initializer)
          case (var equals?, var initializer?)) {
        var variablePiece = buildPiece((b) {
          b.token(variable.name);
          b.space();
          b.token(equals);
        });

        var initializerPiece = nodePiece(initializer, commaAfter: true);

        variables.add(AssignPiece(variablePiece, initializerPiece,
            isValueDelimited: initializer.canBlockSplit));
      } else {
        variables.add(tokenPiece(variable.name, commaAfter: true));
      }
    }

    return VariablePiece(header, variables, hasType: node.type != null);
  }

  @override
  Piece visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    return buildPiece((b) {
      b.visit(node.variables);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitWhileStatement(WhileStatement node) {
    var condition = startControlFlow(node.whileKeyword, node.leftParenthesis,
        node.condition, node.rightParenthesis);

    var body = nodePiece(node.body);

    var piece = IfPiece();
    piece.add(condition, body, isBlock: node.body is Block);
    return piece;
  }

  @override
  Piece visitWildcardPattern(WildcardPattern node) {
    throw UnimplementedError();
  }

  @override
  Piece visitWithClause(WithClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  Piece visitYieldStatement(YieldStatement node) {
    return buildPiece((b) {
      b.token(node.yieldKeyword);
      b.token(node.star);
      b.space();
      b.visit(node.expression);
      b.token(node.semicolon);
    });
  }

  /// Visits [node] and creates a piece from it.
  ///
  /// If [commaAfter] is `true`, looks for a comma token after [node] and
  /// writes it to the piece as well.
  @override
  Piece nodePiece(AstNode node, {bool commaAfter = false}) {
    var result = node.accept(this)!;

    if (commaAfter) {
      var nextToken = node.endToken.next!;
      if (nextToken.lexeme == ',') {
        var comma = tokenPiece(nextToken);
        result = AdjacentPiece([result, comma]);
      }
    }

    return result;
  }
}
