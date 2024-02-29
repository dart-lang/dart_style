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
import '../piece/adjacent_strings.dart';
import '../piece/assign.dart';
import '../piece/case.dart';
import '../piece/constructor.dart';
import '../piece/if.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/variable.dart';
import '../source_code.dart';
import 'adjacent_builder.dart';
import 'chain_builder.dart';
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
    return AdjacentStringsPiece(node.strings.map(nodePiece).toList(),
        indent: node.indentStrings);
  }

  @override
  Piece visitAnnotation(Annotation node) {
    return buildPiece((b) {
      b.token(node.atSign);
      b.visit(node.name);
      b.visit(node.typeArguments);
      b.token(node.period);
      b.visit(node.constructorName);
      b.visit(node.arguments);
    });
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
    return buildPiece((b) {
      b.token(node.assertKeyword);
      b.add(createArgumentList(
        node.leftParenthesis,
        [
          node.condition,
          if (node.message case var message?) message,
        ],
        node.rightParenthesis,
      ));
    });
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
    return tokenPiece(node.name);
  }

  @override
  Piece visitAssignmentExpression(AssignmentExpression node) {
    return createAssignment(
        node.leftHandSide, node.operator, node.rightHandSide);
  }

  @override
  Piece visitAwaitExpression(AwaitExpression node) {
    return createPrefix(node.awaitKeyword, space: true, node.expression);
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
    return ChainBuilder(this, node).build();
  }

  @override
  Piece visitCastPattern(CastPattern node) {
    return createInfix(node.pattern, node.asToken, node.type);
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
          node.hackMacroKeywordForOlderAnalyzer,
          node.mixinKeyword,
          node.classKeyword,
        ],
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
          node.typedefKeyword,
        ],
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
    return createPrefix(node.constKeyword, space: true, node.expression);
  }

  @override
  Piece visitConstructorDeclaration(ConstructorDeclaration node) {
    var header = buildPiece((b) {
      b.metadata(node.metadata);
      b.modifier(node.externalKeyword);
      b.modifier(node.constKeyword);
      b.modifier(node.factoryKeyword);
      b.visit(node.returnType);
      b.token(node.period);
      b.token(node.name);
    });

    var parameters = nodePiece(node.parameters);

    Piece? redirect;
    Piece? initializerSeparator;
    Piece? initializers;
    if (node.redirectedConstructor case var constructor?) {
      var separator = buildPiece((b) {
        b.token(node.separator);
        b.space();
      });

      redirect = AssignPiece(separator, nodePiece(constructor),
          canBlockSplitRight: false);
    } else if (node.initializers.isNotEmpty) {
      initializerSeparator = tokenPiece(node.separator!);
      initializers = createList(node.initializers,
          style: const ListStyle(commas: Commas.nonTrailing));
    }

    var body = createFunctionBody(node.body);

    return ConstructorPiece(header, parameters, body,
        canSplitParameters: node.parameters.parameters
            .canSplit(node.parameters.rightParenthesis),
        hasOptionalParameter: node.parameters.rightDelimiter != null,
        redirect: redirect,
        initializerSeparator: initializerSeparator,
        initializers: initializers);
  }

  @override
  Piece visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    return buildPiece((b) {
      b.token(node.thisKeyword);
      b.token(node.period);
      b.add(createAssignment(node.fieldName, node.equals, node.expression));
    });
  }

  @override
  Piece visitConstructorName(ConstructorName node) {
    var builder = AdjacentBuilder(this);
    if (node.type.importPrefix case var importPrefix?) {
      builder.token(importPrefix.name);
      builder.token(importPrefix.period);
    }

    // The name of the type being constructed.
    var type = node.type;
    builder.token(type.name2);
    builder.visit(type.typeArguments);
    builder.token(type.question);

    // If this is a named constructor, the name.
    if (node.name != null) {
      builder.token(node.period);
      builder.visit(node.name);
    }

    // If there was a prefix or constructor name, then make a splittable piece.
    // Otherwise, the current piece is a simple identifier for the name.
    return builder.build();
  }

  @override
  Piece visitContinueStatement(ContinueStatement node) {
    return createBreak(node.continueKeyword, node.label, node.semicolon);
  }

  @override
  Piece visitDeclaredIdentifier(DeclaredIdentifier node) {
    return createParameter(
        metadata: node.metadata,
        modifiers: [node.keyword],
        node.type,
        node.name);
  }

  @override
  Piece visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    return createPatternVariable(node.keyword, node.type, node.name);
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
    var metadataBuilder = AdjacentBuilder(this);
    metadataBuilder.metadata(node.metadata);

    var header = buildPiece((b) {
      b.token(node.enumKeyword);
      b.space();
      b.token(node.name);
      b.visit(node.typeParameters);
    });

    if (node.members.isEmpty) {
      // If there are no members, format the constants like a delimited list.
      // This keeps the enum declaration on one line if it fits.
      // TODO(tall): The old style preserves blank lines and newlines between
      // enum values. A newline will also force the enum to split even if it
      // would otherwise fit. Do we want to do that with the new style too?
      var builder = DelimitedListBuilder(
          this,
          const ListStyle(
              spaceWhenUnsplit: true, splitListIfBeforeSplits: true));

      builder.addLeftBracket(buildPiece((b) {
        b.add(header);
        b.space();
        b.token(node.leftBracket);
      }));

      node.constants.forEach(builder.visit);
      builder.rightBracket(semicolon: node.semicolon, node.rightBracket);
      metadataBuilder.add(builder.build());
    } else {
      metadataBuilder.add(buildPiece((b) {
        b.add(header);
        b.space();

        // If there are members, format it like a block where each constant and
        // member is on its own line.
        var members = SequenceBuilder(this);
        members.leftBracket(node.leftBracket);

        for (var constant in node.constants) {
          members.addCommentsBefore(constant.firstNonCommentToken);
          members.add(createEnumConstant(constant,
              hasMembers: true,
              isLastConstant: constant == node.constants.last,
              semicolon: node.semicolon));
        }

        // Insert a blank line between the constants and members.
        members.addBlank();

        for (var node in node.members) {
          members.visit(node);

          // If the node has a non-empty braced body, then require a blank line
          // between it and the next node.
          if (node.hasNonEmptyBody) members.addBlank();
        }

        members.rightBracket(node.rightBracket);

        b.add(members.build());
      }));
    }

    return metadataBuilder.build();
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
          canBlockSplitRight: node.expression.canBlockSplit));
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
    return createType(node.metadata, [node.extensionKeyword], node.name,
        typeParameters: node.typeParameters,
        onType: (node.onKeyword, node.extendedType),
        body: (
          leftBracket: node.leftBracket,
          members: node.members,
          rightBracket: node.rightBracket
        ));
  }

  @override
  Piece visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    return createType(
        node.metadata,
        [
          node.extensionKeyword,
          node.typeKeyword,
          if (node.constKeyword case var keyword?) keyword
        ],
        node.name,
        typeParameters: node.typeParameters,
        representation: node.representation,
        implementsClause: node.implementsClause,
        body: (
          leftBracket: node.leftBracket,
          members: node.members,
          rightBracket: node.rightBracket
        ));
  }

  @override
  Piece visitFieldDeclaration(FieldDeclaration node) {
    return buildPiece((b) {
      b.metadata(node.metadata);
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
    if (node.parameters case var parameters?) {
      // A function-typed field formal like:
      //
      //     C(this.fn(parameter));
      return createFunctionType(
          node.type,
          fieldKeyword: node.thisKeyword,
          period: node.period,
          node.name,
          node.typeParameters,
          parameters,
          node.question,
          parameter: node);
    } else {
      return createFormalParameter(
          node,
          mutableKeyword: node.keyword,
          fieldKeyword: node.thisKeyword,
          period: node.period,
          node.type,
          node.name);
    }
  }

  @override
  Piece visitFormalParameterList(FormalParameterList node) {
    // Find the first non-mandatory parameter (if there are any).
    var firstOptional =
        node.parameters.indexWhere((p) => p is DefaultFormalParameter);

    // If all parameters are optional, put the `[` or `{` right after `(`.
    var builder = DelimitedListBuilder(this);

    builder.addLeftBracket(buildPiece((b) {
      b.token(node.leftParenthesis);
      if (node.parameters.isNotEmpty && firstOptional == 0) {
        b.token(node.leftDelimiter);
      }
    }));

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
    return createFor(
        awaitKeyword: node.awaitKeyword,
        forKeyword: node.forKeyword,
        leftParenthesis: node.leftParenthesis,
        forLoopParts: node.forLoopParts,
        rightParenthesis: node.rightParenthesis,
        body: node.body,
        hasBlockBody: node.body.isSpreadCollection,
        forceSplitBody: node.body.isControlFlowElement);
  }

  @override
  Piece visitForStatement(ForStatement node) {
    return createFor(
        awaitKeyword: node.awaitKeyword,
        forKeyword: node.forKeyword,
        leftParenthesis: node.leftParenthesis,
        forLoopParts: node.forLoopParts,
        rightParenthesis: node.rightParenthesis,
        body: node.body,
        hasBlockBody: node.body is Block);
  }

  @override
  Piece visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitForPartsWithExpression(ForPartsWithExpression node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitForPartsWithPattern(ForPartsWithPattern node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  Piece visitFunctionDeclaration(FunctionDeclaration node) {
    return createFunction(
        metadata: node.metadata,
        modifiers: [node.externalKeyword],
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
    return buildPiece((b) {
      b.visit(node.function);
      b.visit(node.typeArguments);
      b.visit(node.argumentList);
    });
  }

  @override
  Piece visitFunctionReference(FunctionReference node) {
    return buildPiece((b) {
      b.visit(node.function);
      b.visit(node.typeArguments);
    });
  }

  @override
  Piece visitFunctionTypeAlias(FunctionTypeAlias node) {
    return buildPiece((b) {
      b.metadata(node.metadata);
      b.token(node.typedefKeyword);
      b.space();
      b.visit(node.returnType, spaceAfter: true);
      b.token(node.name);
      b.visit(node.typeParameters);
      b.visit(node.parameters);
      b.token(node.semicolon);
    });
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
    return buildPiece((b) {
      b.metadata(node.metadata);
      b.token(node.typedefKeyword);
      b.space();
      b.token(node.name);
      b.visit(node.typeParameters);
      b.space();
      b.token(node.equals);
      // Don't bother allowing splitting after the `=`. It's always better to
      // split inside the type parameter, type argument, or parameter lists of
      // the typedef or the aliased type.
      b.space();
      b.visit(node.type);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitHideCombinator(HideCombinator node) {
    throw UnsupportedError('Combinators are handled by createImport().');
  }

  @override
  Piece visitIfElement(IfElement node) {
    var piece = IfPiece(isStatement: false);

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(Token? precedingElse, IfElement ifElement) {
      var spreadThen = ifElement.thenElement.spreadCollection;

      var condition = buildPiece((b) {
        b.token(precedingElse, spaceAfter: true);
        b.add(createIfCondition(
            ifElement.ifKeyword,
            ifElement.leftParenthesis,
            ifElement.expression,
            ifElement.caseClause,
            ifElement.rightParenthesis));

        // Make the `...` part of the header so that IfPiece can correctly
        // constrain the inner collection literal's ListPiece to split.
        if (spreadThen != null) {
          b.space();
          b.token(spreadThen.spreadOperator);
        }
      });

      Piece thenElement;
      if (spreadThen != null) {
        thenElement = nodePiece(spreadThen.expression);
      } else {
        thenElement = nodePiece(ifElement.thenElement);
      }

      // If the then branch of an if element is itself a control flow
      // element, then force the outer if to always split.
      if (ifElement.thenElement.isControlFlowElement) {
        piece.pin(State.split);
      }

      piece.add(condition, thenElement, isBlock: spreadThen != null);

      switch (ifElement.elseElement) {
        case IfElement elseIf:
          // Hit an else-if, so flatten it into the chain with the `else`
          // becoming part of the next section's header.
          traverse(ifElement.elseKeyword, elseIf);

        case var elseElement?:
          var spreadElse = elseElement.spreadCollection;

          // Any other kind of else body ends the chain, with the header for
          // the last section just being the `else` keyword.
          var header = buildPiece((b) {
            b.token(ifElement.elseKeyword!);

            // Make the `...` part of the header so that IfPiece can correctly
            // constrain the inner collection literal's ListPiece to split.
            if (spreadElse != null) {
              b.space();
              b.token(spreadElse.spreadOperator);
            }
          });

          Piece statement;
          if (spreadElse != null) {
            statement = nodePiece(spreadElse.expression);
          } else {
            statement = nodePiece(elseElement);
          }

          piece.add(header, statement, isBlock: spreadElse != null);

          // If the else branch of an if element is itself a control flow
          // element, then force the outer if to always split.
          if (ifElement.thenElement.isControlFlowElement) {
            piece.pin(State.split);
          }

        case null:
          break; // Nothing to do.
      }
    }

    traverse(null, node);
    return piece;
  }

  @override
  Piece visitIfStatement(IfStatement node) {
    var piece = IfPiece(isStatement: true);

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(Token? precedingElse, IfStatement ifStatement) {
      var condition = buildPiece((b) {
        b.token(precedingElse, spaceAfter: true);
        b.add(createIfCondition(
            ifStatement.ifKeyword,
            ifStatement.leftParenthesis,
            ifStatement.expression,
            ifStatement.caseClause,
            ifStatement.rightParenthesis));
        b.space();
      });

      // Edge case: When the then branch is a block and there is an else clause
      // after it, we want to force the block to split even if empty, like:
      //
      //     if (condition) {
      //     } else {
      //       body;
      //     }
      var thenStatement = switch (ifStatement.thenStatement) {
        Block thenBlock when ifStatement.elseStatement != null =>
          createBlock(thenBlock, forceSplit: true),
        _ => nodePiece(ifStatement.thenStatement)
      };

      piece.add(condition, thenStatement,
          isBlock: ifStatement.thenStatement is Block);

      switch (ifStatement.elseStatement) {
        case IfStatement elseIf:
          // Hit an else-if, so flatten it into the chain with the `else`
          // becoming part of the next section's header.
          traverse(ifStatement.elseKeyword, elseIf);

        case var elseStatement?:
          // Any other kind of else body ends the chain, with the header for
          // the last section just being the `else` keyword.
          var header = buildPiece((b) {
            b.token(ifStatement.elseKeyword, spaceAfter: true);
          });
          var statement = nodePiece(elseStatement);
          piece.add(header, statement, isBlock: elseStatement is Block);
      }
    }

    traverse(null, node);

    // If statements almost always split at the clauses unless the if is a
    // simple if with only a single unbraced then statement and no else clause,
    // like:
    //
    //     if (condition) print("ok");
    if (node.thenStatement is Block || node.elseStatement != null) {
      piece.pin(State.split);
    }

    return piece;
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
    var targetPiece = optionalNodePiece(node.target);
    return createIndexExpression(targetPiece, node);
  }

  @override
  Piece visitInstanceCreationExpression(InstanceCreationExpression node) {
    var builder = AdjacentBuilder(this);
    builder.token(node.keyword, spaceAfter: true);

    var constructor = node.constructorName;
    if (constructor.type.importPrefix case var importPrefix?) {
      builder.token(importPrefix.name);
      builder.token(importPrefix.period);
    }

    // The type being constructed.
    var type = constructor.type;
    builder.token(type.name2);
    builder.visit(type.typeArguments);

    // If this is a named constructor call, the name.
    if (constructor.name case var name?) {
      builder.token(constructor.period);
      builder.visit(name);
    }

    builder.visit(node.argumentList);

    return builder.build();
  }

  @override
  Piece visitIntegerLiteral(IntegerLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitInterpolationExpression(InterpolationExpression node) {
    return buildPiece((b) {
      b.token(node.leftBracket);
      b.visit(node.expression);
      b.token(node.rightBracket);
    });
  }

  @override
  Piece visitInterpolationString(InterpolationString node) {
    return pieces.stringLiteralPiece(node.contents,
        isMultiline: (node.parent as StringInterpolation).isMultiline);
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
      b.metadata(node.metadata);
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
      constKeyword: node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  Piece visitListPattern(ListPattern node) {
    return createCollection(
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  Piece visitLogicalAndPattern(LogicalAndPattern node) {
    return createInfixChain<LogicalAndPattern>(
        node,
        precedence: node.operator.type.precedence,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  Piece visitLogicalOrPattern(LogicalOrPattern node) {
    // If a logical or pattern is the outermost pattern in a switch expression
    // case, we want to format it like parallel cases and not indent the
    // subsequent operands.
    var indent = node.parent is! GuardedPattern ||
        node.parent!.parent is! SwitchExpressionCase;

    return createInfixChain<LogicalOrPattern>(
        node,
        precedence: node.operator.type.precedence,
        indent: indent,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  Piece visitMapLiteralEntry(MapLiteralEntry node) {
    return createAssignment(node.key, node.separator, node.value,
        spaceBeforeOperator: false);
  }

  @override
  Piece visitMapPattern(MapPattern node) {
    return createCollection(
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  Piece visitMapPatternEntry(MapPatternEntry node) {
    return createAssignment(node.key, node.separator, node.value,
        spaceBeforeOperator: false);
  }

  @override
  Piece visitMethodDeclaration(MethodDeclaration node) {
    return createFunction(
        metadata: node.metadata,
        modifiers: [node.externalKeyword, node.modifierKeyword],
        returnType: node.returnType,
        propertyKeyword: node.operatorKeyword ?? node.propertyKeyword,
        name: node.name,
        typeParameters: node.typeParameters,
        parameters: node.parameters,
        body: node.body);
  }

  @override
  Piece visitMethodInvocation(MethodInvocation node) {
    // If there's no target, this is a "bare" function call like "foo(1, 2)",
    // or a section in a cascade.
    //
    // If it looks like a constructor or static call, we want to keep the
    // target and method together instead of including the method in the
    // subsequent method chain.
    if (node.target == null || node.looksLikeStaticCall) {
      return buildPiece((b) {
        b.visit(node.target);
        b.token(node.operator);
        b.visit(node.methodName);
        b.visit(node.typeArguments);
        b.visit(node.argumentList);
      });
    }

    return ChainBuilder(this, node).build();
  }

  @override
  Piece visitMixinDeclaration(MixinDeclaration node) {
    return createType(
        node.metadata, [node.baseKeyword, node.mixinKeyword], node.name,
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
    return buildPiece((b) {
      b.token(node.nativeKeyword);
      b.visit(node.stringLiteral, spaceBefore: true);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitNullAssertPattern(NullAssertPattern node) {
    return createPostfix(node.pattern, node.operator);
  }

  @override
  Piece visitNullCheckPattern(NullCheckPattern node) {
    return createPostfix(node.pattern, node.operator);
  }

  @override
  Piece visitNullLiteral(NullLiteral node) {
    return tokenPiece(node.literal);
  }

  @override
  Piece visitObjectPattern(ObjectPattern node) {
    var builder = DelimitedListBuilder(this);

    builder.addLeftBracket(buildPiece((b) {
      b.visit(node.type);
      b.token(node.leftParenthesis);
    }));

    node.fields.forEach(builder.visit);
    builder.rightBracket(node.rightParenthesis);
    return builder.build();
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
    return buildPiece((b) {
      b.token(node.leftParenthesis);
      b.visit(node.pattern);
      b.token(node.rightParenthesis);
    });
  }

  @override
  Piece visitPartDirective(PartDirective node) {
    return buildPiece((b) {
      b.metadata(node.metadata);
      b.token(node.partKeyword);
      b.space();
      b.visit(node.uri);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitPartOfDirective(PartOfDirective node) {
    return buildPiece((b) {
      b.metadata(node.metadata);
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
    return createAssignment(node.pattern, node.equals, node.expression);
  }

  @override
  Piece visitPatternField(PatternField node) {
    return buildPiece((b) {
      b.visit(node.name);
      b.visit(node.pattern);
    });
  }

  @override
  Piece visitPatternFieldName(PatternFieldName node) {
    return buildPiece((b) {
      b.token(node.name);
      b.token(node.colon);
      if (node.name != null) b.space();
    });
  }

  @override
  Piece visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    return buildPiece((b) {
      // If the variable is part of a for loop, it looks weird to force the
      // metadata to split since it's in a sort of expression-ish location:
      //
      //     for (@meta var (x, y) in pairs) ...
      b.metadata(node.metadata,
          inline: node.parent is ForEachPartsWithPattern ||
              node.parent is ForPartsWithPattern);
      b.token(node.keyword);
      b.space();
      b.add(createAssignment(node.pattern, node.equals, node.expression));
    });
  }

  @override
  Piece visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    return buildPiece((b) {
      b.visit(node.declaration);
      b.token(node.semicolon);
    });
  }

  @override
  Piece visitPostfixExpression(PostfixExpression node) {
    return createPostfix(node.operand, node.operator);
  }

  @override
  Piece visitPrefixedIdentifier(PrefixedIdentifier node) {
    return ChainBuilder(this, node).build();
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
    // If there's no target, this is a section in a cascade.
    if (node.target == null) {
      return buildPiece((b) {
        b.token(node.operator);
        b.visit(node.propertyName);
      });
    }

    return ChainBuilder(this, node).build();
  }

  @override
  Piece visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    return buildPiece((b) {
      b.token(node.thisKeyword);
      b.token(node.period);
      b.visit(node.constructorName);
      b.visit(node.argumentList);
    });
  }

  @override
  Piece visitRecordLiteral(RecordLiteral node) {
    return createRecord(
      constKeyword: node.constKeyword,
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
    );
  }

  @override
  Piece visitRecordPattern(RecordPattern node) {
    return createRecord(
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
    );
  }

  @override
  Piece visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    var namedFields = node.namedFields;
    var positionalFields = node.positionalFields;

    // Single positional record types always have a trailing comma.
    var listStyle = positionalFields.length == 1 && namedFields == null
        ? const ListStyle(commas: Commas.alwaysTrailing)
        : const ListStyle(commas: Commas.trailing);
    var builder = DelimitedListBuilder(this, listStyle);

    // If all parameters are optional, put the `{` right after `(`.
    builder.addLeftBracket(buildPiece((b) {
      b.token(node.leftParenthesis);
      if (positionalFields.isEmpty && namedFields != null) {
        b.token(namedFields.leftBracket);
      }
    }));

    for (var positionalField in positionalFields) {
      builder.visit(positionalField);
    }

    Token? rightDelimiter;
    if (namedFields != null) {
      // If we have both positional fields and named fields, then we need to add
      // the left bracket delimiter before the first named field.
      if (positionalFields.isNotEmpty) {
        builder.leftDelimiter(namedFields.leftBracket);
      }
      for (var namedField in namedFields.fields) {
        builder.visit(namedField);
      }
      rightDelimiter = namedFields.rightBracket;
    }

    builder.rightBracket(node.rightParenthesis, delimiter: rightDelimiter);
    return buildPiece((b) {
      b.add(builder.build());
      b.token(node.question);
    });
  }

  @override
  Piece visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    return createRecordTypeField(node);
  }

  @override
  Piece visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    return createRecordTypeField(node);
  }

  @override
  Piece visitRelationalPattern(RelationalPattern node) {
    return buildPiece((b) {
      b.token(node.operator);
      b.space();
      b.visit(node.operand);
    });
  }

  @override
  Piece visitRepresentationConstructorName(RepresentationConstructorName node) {
    return buildPiece((b) {
      b.token(node.period);
      b.token(node.name);
    });
  }

  @override
  Piece visitRepresentationDeclaration(RepresentationDeclaration node) {
    return buildPiece((b) {
      b.visit(node.constructorName);

      var builder = DelimitedListBuilder(this);
      builder.leftBracket(node.leftParenthesis);
      builder.add(createParameter(
          metadata: node.fieldMetadata, node.fieldType, node.fieldName));
      builder.rightBracket(node.rightParenthesis);
      b.add(builder.build());
    });
  }

  @override
  Piece visitRethrowExpression(RethrowExpression node) {
    return tokenPiece(node.rethrowKeyword);
  }

  @override
  Piece visitRestPatternElement(RestPatternElement node) {
    return createPrefix(node.operator, node.pattern);
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
      constKeyword: node.constKeyword,
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
    return createFormalParameter(node, node.type, node.name,
        mutableKeyword: node.keyword);
  }

  @override
  Piece visitSimpleIdentifier(SimpleIdentifier node) {
    return tokenPiece(node.token);
  }

  @override
  Piece visitSimpleStringLiteral(SimpleStringLiteral node) {
    return pieces.stringLiteralPiece(node.literal,
        isMultiline: node.isMultiline);
  }

  @override
  Piece visitSpreadElement(SpreadElement node) {
    return createPrefix(node.spreadOperator, node.expression);
  }

  @override
  Piece visitStringInterpolation(StringInterpolation node) {
    return buildPiece((b) {
      for (var element in node.elements) {
        b.visit(element);
      }
    });
  }

  @override
  Piece visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    return buildPiece((b) {
      b.token(node.superKeyword);
      b.token(node.period);
      b.visit(node.constructorName);
      b.visit(node.argumentList);
    });
  }

  @override
  Piece visitSuperExpression(SuperExpression node) {
    return tokenPiece(node.superKeyword);
  }

  @override
  Piece visitSuperFormalParameter(SuperFormalParameter node) {
    if (node.parameters case var parameters?) {
      // A function-typed super parameter like:
      //
      //     C(super.fn(parameter));
      return createFunctionType(
          node.type,
          fieldKeyword: node.superKeyword,
          period: node.period,
          node.name,
          node.typeParameters,
          parameters,
          node.question,
          parameter: node);
    } else {
      return createFormalParameter(
          node,
          mutableKeyword: node.keyword,
          fieldKeyword: node.superKeyword,
          period: node.period,
          node.type,
          node.name);
    }
  }

  @override
  Piece visitSwitchExpression(SwitchExpression node) {
    var value = startControlFlow(node.switchKeyword, node.leftParenthesis,
        node.expression, node.rightParenthesis);

    var list = DelimitedListBuilder(this,
        const ListStyle(spaceWhenUnsplit: true, splitListIfBeforeSplits: true));

    list.addLeftBracket(buildPiece((b) {
      b.add(value);
      b.space();
      b.token(node.leftBracket);
    }));

    for (var member in node.cases) {
      list.visit(member);
    }

    list.rightBracket(node.rightBracket);
    return list.build();
  }

  @override
  Piece visitSwitchExpressionCase(SwitchExpressionCase node) {
    var patternPiece = nodePiece(node.guardedPattern.pattern);

    var guardPiece = optionalNodePiece(node.guardedPattern.whenClause);
    var arrowPiece = tokenPiece(node.arrow);
    var bodyPiece = nodePiece(node.expression);

    return CaseExpressionPiece(patternPiece, guardPiece, arrowPiece, bodyPiece,
        canBlockSplitPattern: node.guardedPattern.pattern.canBlockSplit,
        patternIsLogicalOr: node.guardedPattern.pattern is LogicalOrPattern,
        canBlockSplitBody: node.expression.canBlockSplit);
  }

  @override
  Piece visitSwitchStatement(SwitchStatement node) {
    return buildPiece((b) {
      b.add(startControlFlow(node.switchKeyword, node.leftParenthesis,
          node.expression, node.rightParenthesis));
      b.space();

      var sequence = SequenceBuilder(this);
      sequence.leftBracket(node.leftBracket);

      for (var member in node.members) {
        for (var label in member.labels) {
          sequence.visit(label);
        }

        sequence.addCommentsBefore(member.keyword);

        var casePiece = buildPiece((b) {
          b.token(member.keyword);

          switch (member) {
            case SwitchCase():
              b.space();
              b.visit(member.expression);
            case SwitchPatternCase():
              b.space();

              var patternPiece = nodePiece(member.guardedPattern.pattern);
              var guardPiece =
                  optionalNodePiece(member.guardedPattern.whenClause);

              b.add(CaseStatementPiece(patternPiece, guardPiece));

            case SwitchDefault():
              break; // Nothing to do.
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

      sequence.rightBracket(node.rightBracket);
      b.add(sequence.build());
    });
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
    return createPrefix(node.throwKeyword, space: true, node.expression);
  }

  @override
  Piece visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    return buildPiece((b) {
      b.metadata(node.metadata);
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
      b.metadata(node.metadata, inline: true);
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
    var header = buildPiece((b) {
      // If the variable is part of a for loop, it looks weird to force the
      // metadata to split since it's in a sort of expression-ish location:
      //
      //     for (@meta var x in list) ...
      b.metadata(node.metadata,
          inline: node.parent is ForPartsWithDeclarations);
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
        var variablePiece = tokenPiece(variable.name);

        var equalsPiece = buildPiece((b) {
          b.space();
          b.token(equals);
        });

        var initializerPiece = nodePiece(initializer, commaAfter: true);

        variables.add(AssignPiece(
            left: variablePiece,
            equalsPiece,
            initializerPiece,
            canBlockSplitRight: initializer.canBlockSplit));
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
  Piece visitWhenClause(WhenClause node) {
    return createPrefix(node.whenKeyword, space: true, node.expression);
  }

  @override
  Piece visitWhileStatement(WhileStatement node) {
    var condition = buildPiece((b) {
      b.add(startControlFlow(node.whileKeyword, node.leftParenthesis,
          node.condition, node.rightParenthesis));
      b.space();
    });

    var body = nodePiece(node.body);

    var piece = IfPiece(isStatement: true);
    piece.add(condition, body, isBlock: node.body is Block);
    return piece;
  }

  @override
  Piece visitWildcardPattern(WildcardPattern node) {
    return createPatternVariable(node.keyword, node.type, node.name);
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

  /// Visits [node] and creates a piece from it if not `null`.
  ///
  /// Otherwise returns `null`.
  @override
  Piece? optionalNodePiece(AstNode? node) {
    if (node == null) return null;
    return nodePiece(node);
  }
}
