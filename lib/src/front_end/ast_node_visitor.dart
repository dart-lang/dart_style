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
import '../piece/assign.dart';
import '../piece/case.dart';
import '../piece/constructor.dart';
import '../piece/control_flow.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/type.dart';
import '../piece/variable.dart';
import '../profile.dart';
import '../source_code.dart';
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
class AstNodeVisitor extends ThrowingAstVisitor<void> with PieceFactory {
  @override
  final PieceWriter pieces;

  @override
  final CommentWriter comments;

  /// The context set by the surrounding AstNode when visiting a child, or
  /// [NodeContext.none] if the parent node doesn't set a context.
  @override
  NodeContext get parentContext => _parentContext;
  NodeContext _parentContext = NodeContext.none;

  /// Create a new visitor that will be called to visit the code in [source].
  factory AstNodeVisitor(
      DartFormatter formatter, LineInfo lineInfo, SourceCode source) {
    var comments = CommentWriter(lineInfo);
    var pieces = PieceWriter(formatter, source, comments);
    return AstNodeVisitor._(pieces, comments);
  }

  AstNodeVisitor._(this.pieces, this.comments) {
    pieces.bindVisitor(this);
  }

  /// Visits [node] and returns the formatted result.
  ///
  /// Returns a [SourceCode] containing the resulting formatted source and
  /// updated selection, if any.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  SourceCode run(AstNode node) {
    Profile.begin('AstNodeVisitor.run()');

    Profile.begin('AstNodeVisitor build Piece tree');

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

      // Add a blank line between directives and declarations.
      sequence.addBlank();

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

    var unitPiece = sequence.build();

    Profile.end('AstNodeVisitor build Piece tree');

    // Finish writing and return the complete result.
    var result = pieces.finish(unitPiece);

    Profile.end('AstNodeVisitor.run()');

    return result;
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    var piece = InfixPiece(const [], node.strings.map(nodePiece).toList(),
        indent: node.indentStrings);

    // Adjacent strings always split.
    piece.pin(State.split);

    pieces.add(piece);
  }

  @override
  void visitAnnotation(Annotation node) {
    pieces.token(node.atSign);
    pieces.visit(node.name);
    pieces.visit(node.typeArguments);
    pieces.token(node.period);
    pieces.visit(node.constructorName);
    pieces.visit(node.arguments);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    writeArgumentList(
        node.leftParenthesis, node.arguments, node.rightParenthesis);
  }

  @override
  void visitAsExpression(AsExpression node) {
    writeInfix(node.expression, node.asOperator, node.type);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    pieces.token(node.assertKeyword);
    writeArgumentList(
      node.leftParenthesis,
      [
        node.condition,
        if (node.message case var message?) message,
      ],
      node.rightParenthesis,
    );
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    pieces.token(node.assertKeyword);
    writeArgumentList(
        node.leftParenthesis,
        [
          node.condition,
          if (node.message case var message?) message,
        ],
        node.rightParenthesis);
    pieces.token(node.semicolon);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    pieces.token(node.name);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    writeAssignment(node.leftHandSide, node.operator, node.rightHandSide);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    writePrefix(node.awaitKeyword, space: true, node.expression);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    writeInfixChain<BinaryExpression>(
        node,
        precedence: node.operator.type.precedence,
        indent: _parentContext != NodeContext.assignment,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  void visitBlock(Block node) {
    writeBlock(node);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    pieces.space();
    writeFunctionBodyModifiers(node);
    pieces.visit(node.block);
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    pieces.token(node.literal);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    writeBreak(node.breakKeyword, node.label, node.semicolon);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    pieces.add(ChainBuilder(this, node).buildCascade());
  }

  @override
  void visitCastPattern(CastPattern node) {
    writeInfix(node.pattern, node.asToken, node.type);
  }

  @override
  void visitCatchClause(CatchClause node) {
    throw UnsupportedError('This node is handled by visitTryStatement().');
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    pieces.token(node.name);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    writeType(
        node.metadata,
        [
          node.abstractKeyword,
          node.baseKeyword,
          node.interfaceKeyword,
          node.finalKeyword,
          node.sealedKeyword,
          node.macroKeyword,
          node.mixinKeyword,
          node.classKeyword,
        ],
        node.name,
        typeParameters: node.typeParameters,
        extendsClause: node.extendsClause,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
        nativeClause: node.nativeClause, body: () {
      return pieces.build(() {
        writeBody(node.leftBracket, node.members, node.rightBracket);
      });
    });
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    writeType(
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
        bodyType: TypeBodyType.semicolon,
        body: () => tokenPiece(node.semicolon));
  }

  @override
  void visitComment(Comment node) {
    throw UnsupportedError('Comments should be handled elsewhere.');
  }

  @override
  void visitCommentReference(CommentReference node) {
    throw UnsupportedError('Comments should be handled elsewhere.');
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    throw UnsupportedError(
        'CompilationUnit should be handled directly by run().');
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    // Hoist any comments before the condition operand so they don't force the
    // conditional expression to split.
    var leadingComments = pieces.takeCommentsBefore(node.firstNonCommentToken);

    // Flatten a series of else-if-like chained conditionals into a single long
    // infix piece. This produces a flattened style like:
    //
    //     condition
    //     ? thenBranch
    //     : condition2
    //     ? thenBranch2
    //     : elseBranch;
    //
    // This (arguably) looks nicer. More importantly, it means that all but the
    // last operand can be formatted separately, which is important to avoid
    // pathological performance in the solved with long nested conditional
    // chains.
    var operands = [nodePiece(node.condition)];

    void addOperand(Token operator, Expression operand) {
      operands.add(pieces.build(() {
        pieces.token(operator);
        pieces.space();
        pieces.visit(operand, context: NodeContext.conditionalBranch);
      }));
    }

    var conditional = node;
    while (true) {
      addOperand(conditional.question, conditional.thenExpression);

      var elseBranch = conditional.elseExpression;
      if (elseBranch is ConditionalExpression) {
        addOperand(conditional.colon, elseBranch.condition);
        conditional = elseBranch;
      } else {
        addOperand(conditional.colon, conditional.elseExpression);
        break;
      }
    }

    var piece = InfixPiece(leadingComments, operands);

    // If conditional expressions are directly nested, force them all to split,
    // both parents and children.
    if (_parentContext == NodeContext.conditionalBranch ||
        node.thenExpression is ConditionalExpression ||
        node.elseExpression is ConditionalExpression) {
      piece.pin(State.split);
    }

    pieces.add(piece);
  }

  @override
  void visitConfiguration(Configuration node) {
    pieces.token(node.ifKeyword);
    pieces.space();
    pieces.token(node.leftParenthesis);

    if (node.equalToken case var equals?) {
      writeInfix(node.name, equals, node.value!, hanging: true);
    } else {
      pieces.visit(node.name);
    }

    pieces.token(node.rightParenthesis);
    pieces.space();
    pieces.visit(node.uri);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    writePrefix(node.constKeyword, space: true, node.expression);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    var header = pieces.build(metadata: node.metadata, () {
      pieces.modifier(node.externalKeyword);
      pieces.modifier(node.constKeyword);
      pieces.modifier(node.factoryKeyword);
      pieces.visit(node.returnType);
      pieces.token(node.period);
      pieces.token(node.name);
    });

    var parameters = nodePiece(node.parameters);

    Piece? redirect;
    Piece? initializerSeparator;
    Piece? initializers;
    if (node.redirectedConstructor case var constructor?) {
      var separator = pieces.build(() {
        pieces.token(node.separator);
        pieces.space();
      });

      redirect = AssignPiece(
          separator, nodePiece(constructor, context: NodeContext.assignment),
          canBlockSplitRight: false);
    } else if (node.initializers.isNotEmpty) {
      initializerSeparator = tokenPiece(node.separator!);
      initializers = createCommaSeparated(node.initializers);
    }

    var body = nodePiece(node.body);

    pieces.add(ConstructorPiece(header, parameters, body,
        canSplitParameters: node.parameters.parameters
            .canSplit(node.parameters.rightParenthesis),
        hasOptionalParameter: node.parameters.rightDelimiter != null,
        redirect: redirect,
        initializerSeparator: initializerSeparator,
        initializers: initializers));
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    pieces.token(node.thisKeyword);
    pieces.token(node.period);
    writeAssignment(node.fieldName, node.equals, node.expression);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    if (node.type.importPrefix case var importPrefix?) {
      pieces.token(importPrefix.name);
      pieces.token(importPrefix.period);
    }

    // The name of the type being constructed.
    var type = node.type;
    pieces.token(type.name2);
    pieces.visit(type.typeArguments);
    pieces.token(type.question);

    // If this is a named constructor, the name.
    if (node.name != null) {
      pieces.token(node.period);
      pieces.visit(node.name);
    }
  }

  @override
  void visitConstructorSelector(ConstructorSelector node) {
    pieces.token(node.period);
    pieces.visit(node.name);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    writeBreak(node.continueKeyword, node.label, node.semicolon);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    writeParameter(
        metadata: node.metadata,
        modifiers: [node.keyword],
        node.type,
        node.name);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    writePatternVariable(node.keyword, node.type, node.name);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    // Visit the inner parameter. It will then access its parent to extract the
    // default value.
    pieces.visit(node.parameter);
  }

  @override
  void visitDoStatement(DoStatement node) {
    pieces.token(node.doKeyword);
    pieces.space();
    pieces.visit(node.body);
    pieces.space();
    pieces.token(node.whileKeyword);
    pieces.space();
    pieces.token(node.leftParenthesis);
    pieces.visit(node.condition);
    pieces.token(node.rightParenthesis);
    pieces.token(node.semicolon);
  }

  @override
  void visitDottedName(DottedName node) {
    writeDotted(node.components);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    pieces.token(node.literal);
  }

  @override
  void visitEmptyFunctionBody(EmptyFunctionBody node) {
    pieces.token(node.semicolon);
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {
    pieces.token(node.semicolon);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    pieces.add(createEnumConstant(node));
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    writeType(node.metadata, [node.enumKeyword], node.name,
        typeParameters: node.typeParameters,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
        bodyType: node.members.isEmpty ? TypeBodyType.list : TypeBodyType.block,
        body: () {
      if (node.members.isEmpty) {
        // If there are no members, format the constants like a delimited list.
        // This keeps the enum declaration on one line if it fits.
        var builder =
            DelimitedListBuilder(this, const ListStyle(spaceWhenUnsplit: true));

        builder.leftBracket(node.leftBracket);
        node.constants.forEach(builder.visit);
        builder.rightBracket(semicolon: node.semicolon, node.rightBracket);
        return builder.build();
      } else {
        // If there are members, format it like a block where each constant and
        // member is on its own line.
        var builder = SequenceBuilder(this);
        builder.leftBracket(node.leftBracket);

        for (var constant in node.constants) {
          builder.addCommentsBefore(constant.firstNonCommentToken);
          builder.add(createEnumConstant(constant,
              isLastConstant: constant == node.constants.last,
              semicolon: node.semicolon));
        }

        // Insert a blank line between the constants and members.
        builder.addBlank();

        for (var node in node.members) {
          builder.visit(node);

          // If the node has a non-empty braced body, then require a blank line
          // between it and the next node.
          if (node.hasNonEmptyBody) builder.addBlank();
        }

        builder.rightBracket(node.rightBracket);
        return builder.build();
      }
    });
  }

  @override
  void visitExportDirective(ExportDirective node) {
    writeImport(node, node.exportKeyword);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    var operatorPiece = pieces.build(() {
      pieces.space();
      writeFunctionBodyModifiers(node);
      pieces.token(node.functionDefinition);
    });

    var expression =
        nodePiece(node.expression, context: NodeContext.assignment);

    pieces.add(AssignPiece(operatorPiece, expression,
        canBlockSplitRight: node.expression.canBlockSplit));
    pieces.token(node.semicolon);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    pieces.visit(node.expression);
    pieces.token(node.semicolon);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    (Token, TypeAnnotation)? onType;
    if (node.onClause case var onClause?) {
      onType = (onClause.onKeyword, onClause.extendedType);
    }

    writeType(node.metadata, [node.extensionKeyword], node.name,
        typeParameters: node.typeParameters, onType: onType, body: () {
      return pieces.build(() {
        writeBody(node.leftBracket, node.members, node.rightBracket);
      });
    });
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    writeType(
        node.metadata,
        [
          node.extensionKeyword,
          node.typeKeyword,
          if (node.constKeyword case var keyword?) keyword
        ],
        node.name,
        typeParameters: node.typeParameters,
        representation: node.representation,
        implementsClause: node.implementsClause, body: () {
      return pieces.build(() {
        writeBody(node.leftBracket, node.members, node.rightBracket);
      });
    });
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    pieces.withMetadata(node.metadata, () {
      pieces.modifier(node.externalKeyword);
      pieces.modifier(node.staticKeyword);
      pieces.modifier(node.abstractKeyword);
      pieces.modifier(node.covariantKeyword);
      pieces.visit(node.fields);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    if (node.parameters case var parameters?) {
      // A function-typed field formal like:
      //
      //     C(this.fn(parameter));
      writeFunctionType(
          node.type,
          fieldKeyword: node.thisKeyword,
          period: node.period,
          node.name,
          node.typeParameters,
          parameters,
          node.question,
          parameter: node);
    } else {
      writeFormalParameter(
          node,
          mutableKeyword: node.keyword,
          fieldKeyword: node.thisKeyword,
          period: node.period,
          node.type,
          node.name);
    }
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    // Find the first non-mandatory parameter (if there are any).
    var firstOptional =
        node.parameters.indexWhere((p) => p is DefaultFormalParameter);

    // If the parameter list is completely empty, write the brackets inline so
    // that we generate fewer separate pieces.
    if (!node.parameters.canSplit(node.rightParenthesis)) {
      pieces.token(node.leftParenthesis);
      pieces.token(node.rightParenthesis);
      return;
    }

    // If all parameters are optional, put the `[` or `{` right after `(`.
    var builder = DelimitedListBuilder(this);

    builder.addLeftBracket(pieces.build(() {
      pieces.token(node.leftParenthesis);
      if (node.parameters.isNotEmpty && firstOptional == 0) {
        pieces.token(node.leftDelimiter);
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
    pieces.add(builder.build());
  }

  @override
  void visitForElement(ForElement node) {
    writeFor(
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
  void visitForStatement(ForStatement node) {
    writeFor(
        awaitKeyword: node.awaitKeyword,
        forKeyword: node.forKeyword,
        leftParenthesis: node.leftParenthesis,
        forLoopParts: node.forLoopParts,
        rightParenthesis: node.rightParenthesis,
        body: node.body,
        hasBlockBody: node.body is Block);
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitForPartsWithExpression(ForPartsWithExpression node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitForPartsWithPattern(ForPartsWithPattern node) {
    throw UnsupportedError('This node is handled by createFor().');
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    writeFunction(
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
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    pieces.add(nodePiece(node.functionDeclaration));
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    writeFunction(
        typeParameters: node.typeParameters,
        parameters: node.parameters,
        body: node.body);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    pieces.visit(node.function);
    pieces.visit(node.typeArguments);
    pieces.visit(node.argumentList);
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    pieces.visit(node.function);
    pieces.visit(node.typeArguments);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    pieces.withMetadata(node.metadata, () {
      pieces.token(node.typedefKeyword);
      pieces.space();
      pieces.visit(node.returnType, spaceAfter: true);
      pieces.token(node.name);
      pieces.visit(node.typeParameters);
      pieces.visit(node.parameters);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    writeFunctionType(
        parameter: node,
        node.returnType,
        node.name,
        node.typeParameters,
        node.parameters,
        node.question);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    writeFunctionType(node.returnType, node.functionKeyword,
        node.typeParameters, node.parameters, node.question);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    pieces.withMetadata(node.metadata, () {
      pieces.token(node.typedefKeyword);
      pieces.space();
      pieces.token(node.name);
      pieces.visit(node.typeParameters);
      pieces.space();
      pieces.add(AssignPiece(tokenPiece(node.equals), nodePiece(node.type)));
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitHideCombinator(HideCombinator node) {
    throw UnsupportedError('Combinators are handled by createImport().');
  }

  @override
  void visitIfElement(IfElement node) {
    var piece = ControlFlowPiece(isStatement: false);

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(Token? precedingElse, IfElement ifElement) {
      var spreadThen = ifElement.thenElement.spreadCollection;

      var condition = pieces.build(() {
        pieces.token(precedingElse, spaceAfter: true);
        writeIfCondition(
            ifElement.ifKeyword,
            ifElement.leftParenthesis,
            ifElement.expression,
            ifElement.caseClause,
            ifElement.rightParenthesis);

        // Make the `...` part of the header so that IfPiece can correctly
        // constrain the inner collection literal's ListPiece to split.
        if (spreadThen != null) {
          pieces.space();
          pieces.token(spreadThen.spreadOperator);
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
          var header = pieces.build(() {
            pieces.token(ifElement.elseKeyword!);

            // Make the `...` part of the header so that IfPiece can correctly
            // constrain the inner collection literal's ListPiece to split.
            if (spreadElse != null) {
              pieces.space();
              pieces.token(spreadElse.spreadOperator);
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
    pieces.add(piece);
  }

  @override
  void visitIfStatement(IfStatement node) {
    var piece = ControlFlowPiece();

    // Recurses through the else branches to flatten them into a linear if-else
    // chain handled by a single [IfPiece].
    void traverse(Token? precedingElse, IfStatement ifStatement) {
      var condition = pieces.build(() {
        pieces.token(precedingElse, spaceAfter: true);
        writeIfCondition(
            ifStatement.ifKeyword,
            ifStatement.leftParenthesis,
            ifStatement.expression,
            ifStatement.caseClause,
            ifStatement.rightParenthesis);
        pieces.space();
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
          pieces.build(() {
            writeBlock(thenBlock, forceSplit: true);
          }),
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
          var header = pieces.build(() {
            pieces.token(ifStatement.elseKeyword, spaceAfter: true);
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

    pieces.add(piece);
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitImportDirective(ImportDirective node) {
    writeImport(node, node.importKeyword,
        deferredKeyword: node.deferredKeyword,
        asKeyword: node.asKeyword,
        prefix: node.prefix);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    pieces.visit(node.target);
    writeIndexExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    pieces.token(node.keyword, spaceAfter: true);

    var constructor = node.constructorName;
    if (constructor.type.importPrefix case var importPrefix?) {
      pieces.token(importPrefix.name);
      pieces.token(importPrefix.period);
    }

    // The type being constructed.
    var type = constructor.type;
    pieces.token(type.name2);
    pieces.visit(type.typeArguments);

    // If this is a named constructor call, the name.
    if (constructor.name case var name?) {
      pieces.token(constructor.period);
      pieces.visit(name);
    }

    pieces.visit(node.argumentList);
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    pieces.token(node.literal);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    var piece = pieces.build(() {
      pieces.token(node.leftBracket);
      pieces.visit(node.expression);
      pieces.token(node.rightBracket);
    });

    // Don't allow splitting inside interpolated expressions (except for
    // mandatory splits from comments and sequences). Splits inside
    // interpolations almost never look good. It's usually better to just let
    // the lines overflow. More importantly, a single string literal with many
    // interpolations can easily lead to combinatorial performance in the
    // solver.
    // TODO(rnystrom): Traversing the entire interpolation Piece tree and
    // pinning it feels sort of inelegant. Is there a cleaner approach?
    void traverse(Piece piece) {
      piece.preventSplit();
      piece.forEachChild(traverse);
    }

    traverse(piece);

    pieces.add(piece);
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    if (_parentContext == NodeContext.multilineStringInterpolation) {
      pieces.multilineToken(node.contents);
    } else {
      pieces.token(node.contents);
    }
  }

  @override
  void visitIsExpression(IsExpression node) {
    writeInfix(
        node.expression,
        node.isOperator,
        operator2: node.notOperator,
        node.type);
  }

  @override
  void visitLabel(Label node) {
    pieces.visit(node.label);
    pieces.token(node.colon);
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    var sequence = SequenceBuilder(this);
    for (var label in node.labels) {
      sequence.visit(label);
    }

    sequence.visit(node.statement);
    pieces.add(sequence.build());
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    pieces.withMetadata(node.metadata, () {
      pieces.token(node.libraryKeyword);
      pieces.visit(node.name2, spaceBefore: true);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitLibraryIdentifier(LibraryIdentifier node) {
    writeDotted(node.components);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    writeCollection(
      constKeyword: node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
      splitOnNestedCollection: true,
      preserveNewlines: true,
    );
  }

  @override
  void visitListPattern(ListPattern node) {
    writeCollection(
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  void visitLogicalAndPattern(LogicalAndPattern node) {
    // If a logical and pattern occurs inside a map pattern entry, we want to
    // format the operands in parallel, like:
    //
    //     var {
    //       key:
    //         operand1 &&
    //         operand2,
    //     } = value;
    var indent = _parentContext != NodeContext.assignment;

    writeInfixChain<LogicalAndPattern>(
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
  void visitLogicalOrPattern(LogicalOrPattern node) {
    // If a logical and pattern occurs inside a map pattern entry, we want to
    // format the operands in parallel, like:
    //
    //     var {
    //       key:
    //         operand1 &&
    //         operand2,
    //     } = value;
    //
    // Also, if it's the outermost pattern in a switch expression case, we
    // flatten the operands like parallel cases:
    //
    //     e = switch (obj) {
    //       operand1 ||
    //       operand2 => value,
    //     };
    var indent = _parentContext != NodeContext.assignment &&
        _parentContext != NodeContext.switchExpressionCase;

    writeInfixChain<LogicalOrPattern>(
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
  void visitMapLiteralEntry(MapLiteralEntry node) {
    writeAssignment(node.key, node.separator, node.value);
  }

  @override
  void visitMapPattern(MapPattern node) {
    writeCollection(
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    writeAssignment(node.key, node.separator, node.value);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    writeFunction(
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
  void visitMethodInvocation(MethodInvocation node) {
    // If there's no target, this is a "bare" function call like "foo(1, 2)",
    // or a section in a cascade.
    //
    // If it looks like a constructor or static call, we want to keep the
    // target and method together instead of including the method in the
    // subsequent method chain.
    if (node.target == null || node.looksLikeStaticCall) {
      pieces.visit(node.target);
      pieces.token(node.operator);
      pieces.visit(node.methodName);
      pieces.visit(node.typeArguments);
      pieces.visit(node.argumentList);
      return;
    }

    writeChain(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    writeType(node.metadata, [node.baseKeyword, node.mixinKeyword], node.name,
        typeParameters: node.typeParameters,
        onClause: node.onClause,
        implementsClause: node.implementsClause, body: () {
      return pieces.build(() {
        writeBody(node.leftBracket, node.members, node.rightBracket);
      });
    });
  }

  @override
  void visitMixinOnClause(MixinOnClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    writeAssignment(node.name.label, node.name.colon, node.expression);
  }

  @override
  void visitNamedType(NamedType node) {
    pieces.token(node.importPrefix?.name);
    pieces.token(node.importPrefix?.period);
    pieces.token(node.name2);
    pieces.visit(node.typeArguments);
    pieces.token(node.question);
  }

  @override
  void visitNativeClause(NativeClause node) {
    pieces.token(node.nativeKeyword);
    pieces.visit(node.name, spaceBefore: true);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    pieces.space();
    pieces.token(node.nativeKeyword);
    pieces.visit(node.stringLiteral, spaceBefore: true);
    pieces.token(node.semicolon);
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    writePostfix(node.pattern, node.operator);
  }

  @override
  void visitNullCheckPattern(NullCheckPattern node) {
    writePostfix(node.pattern, node.operator);
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    pieces.token(node.literal);
  }

  @override
  void visitObjectPattern(ObjectPattern node) {
    // If the object pattern is completely empty, write it inline so that we
    // create fewer pieces.
    if (!node.fields.canSplit(node.rightParenthesis)) {
      pieces.visit(node.type);
      pieces.token(node.leftParenthesis);
      pieces.token(node.rightParenthesis);
      return;
    }

    var builder = DelimitedListBuilder(this);

    builder.addLeftBracket(pieces.build(() {
      pieces.visit(node.type);
      pieces.token(node.leftParenthesis);
    }));

    node.fields.forEach(builder.visit);
    builder.rightBracket(node.rightParenthesis);
    pieces.add(builder.build());
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    pieces.token(node.leftParenthesis);
    pieces.visit(node.expression);
    pieces.token(node.rightParenthesis);
  }

  @override
  void visitParenthesizedPattern(ParenthesizedPattern node) {
    pieces.token(node.leftParenthesis);
    pieces.visit(node.pattern);
    pieces.token(node.rightParenthesis);
  }

  @override
  void visitPartDirective(PartDirective node) {
    pieces.withMetadata(node.metadata, () {
      pieces.token(node.partKeyword);
      pieces.space();
      pieces.visit(node.uri);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    pieces.withMetadata(node.metadata, () {
      pieces.token(node.partKeyword);
      pieces.space();
      pieces.token(node.ofKeyword);
      pieces.space();

      // Part-of may have either a name or a URI. Only one of these will be
      // non-null. We visit both since visit() ignores null.
      pieces.visit(node.libraryName);
      pieces.visit(node.uri);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    writeAssignment(node.pattern, node.equals, node.expression);
  }

  @override
  void visitPatternField(PatternField node) {
    pieces.visit(node.name);
    pieces.visit(node.pattern);
  }

  @override
  void visitPatternFieldName(PatternFieldName node) {
    pieces.token(node.name);
    pieces.token(node.colon);
    if (node.name != null) pieces.space();
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    pieces.withMetadata(node.metadata,
        // If the variable is part of a for loop, it looks weird to force the
        // metadata to split since it's in a sort of expression-ish location:
        //
        //     for (@meta var (x, y) in pairs) ...
        inlineMetadata: _parentContext == NodeContext.forLoopVariable, () {
      pieces.token(node.keyword);
      pieces.space();
      writeAssignment(node.pattern, node.equals, node.expression);
    });
  }

  @override
  void visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    pieces.visit(node.declaration);
    pieces.token(node.semicolon);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    writePostfix(node.operand, node.operator);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    writeChain(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    pieces.token(node.operator);

    // Edge case: put a space after "-" if the operand is "-" or "--" so that
    // we don't merge the operator tokens.
    if (node.operand
        case PrefixExpression(operator: Token(lexeme: '-' || '--'))) {
      pieces.space();
    }

    pieces.visit(node.operand);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    // If there's no target, this is a section in a cascade.
    if (node.target == null) {
      pieces.token(node.operator);
      pieces.visit(node.propertyName);
      return;
    }

    writeChain(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    pieces.token(node.thisKeyword);
    pieces.token(node.period);
    pieces.visit(node.constructorName);
    pieces.visit(node.argumentList);
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    writeRecord(
        constKeyword: node.constKeyword,
        node.leftParenthesis,
        node.fields,
        node.rightParenthesis,
        preserveNewlines: true);
  }

  @override
  void visitRecordPattern(RecordPattern node) {
    writeRecord(node.leftParenthesis, node.fields, node.rightParenthesis);
  }

  @override
  void visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    var namedFields = node.namedFields;
    var positionalFields = node.positionalFields;

    // Single positional record types always have a trailing comma.
    var listStyle = positionalFields.length == 1 && namedFields == null
        ? const ListStyle(commas: Commas.alwaysTrailing)
        : const ListStyle(commas: Commas.trailing);
    var builder = DelimitedListBuilder(this, listStyle);

    // If all parameters are optional, put the `{` right after `(`.
    builder.addLeftBracket(pieces.build(() {
      pieces.token(node.leftParenthesis);
      if (positionalFields.isEmpty && namedFields != null) {
        pieces.token(namedFields.leftBracket);
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
    pieces.add(builder.build());
    pieces.token(node.question);
  }

  @override
  void visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    writeRecordTypeField(node);
  }

  @override
  void visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    writeRecordTypeField(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    pieces.token(node.operator);
    pieces.space();
    pieces.visit(node.operand);
  }

  @override
  void visitRepresentationConstructorName(RepresentationConstructorName node) {
    pieces.token(node.period);
    pieces.token(node.name);
  }

  @override
  void visitRepresentationDeclaration(RepresentationDeclaration node) {
    pieces.visit(node.constructorName);

    var builder = DelimitedListBuilder(this);
    builder.leftBracket(node.leftParenthesis);
    builder.add(pieces.build(() {
      writeParameter(
          metadata: node.fieldMetadata, node.fieldType, node.fieldName);
    }));
    builder.rightBracket(node.rightParenthesis);
    pieces.add(builder.build());
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    pieces.token(node.rethrowKeyword);
  }

  @override
  void visitRestPatternElement(RestPatternElement node) {
    writePrefix(node.operator, node.pattern);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    pieces.token(node.returnKeyword);
    pieces.visit(node.expression, spaceBefore: true);
    pieces.token(node.semicolon);
  }

  @override
  void visitScriptTag(ScriptTag node) {
    pieces.token(node.scriptTag);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    writeCollection(
      constKeyword: node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
      splitOnNestedCollection: true,
      preserveNewlines: true,
    );
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    throw UnsupportedError('Combinators are handled by createImport().');
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    writeFormalParameter(node, node.type, node.name,
        mutableKeyword: node.keyword);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    pieces.token(node.token);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.isMultiline) {
      pieces.multilineToken(node.literal);
    } else {
      pieces.token(node.literal);
    }
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    writePrefix(node.spreadOperator, node.expression);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    for (var element in node.elements) {
      pieces.visit(element,
          context: node.isMultiline
              ? NodeContext.multilineStringInterpolation
              : NodeContext.none);
    }
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    pieces.token(node.superKeyword);
    pieces.token(node.period);
    pieces.visit(node.constructorName);
    pieces.visit(node.argumentList);
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    pieces.token(node.superKeyword);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    if (node.parameters case var parameters?) {
      // A function-typed super parameter like:
      //
      //     C(super.fn(parameter));
      writeFunctionType(
          node.type,
          fieldKeyword: node.superKeyword,
          period: node.period,
          node.name,
          node.typeParameters,
          parameters,
          node.question,
          parameter: node);
    } else {
      writeFormalParameter(
          node,
          mutableKeyword: node.keyword,
          fieldKeyword: node.superKeyword,
          period: node.period,
          node.type,
          node.name);
    }
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    var list =
        DelimitedListBuilder(this, const ListStyle(spaceWhenUnsplit: true));

    list.addLeftBracket(pieces.build(() {
      writeControlFlowStart(node.switchKeyword, node.leftParenthesis,
          node.expression, node.rightParenthesis);
      pieces.space();
      pieces.token(node.leftBracket);
    }));

    for (var member in node.cases) {
      list.visit(member);
    }

    list.rightBracket(node.rightBracket);
    pieces.add(list.build());
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    var patternPiece = nodePiece(node.guardedPattern.pattern,
        context: NodeContext.switchExpressionCase);

    var guardPiece = optionalNodePiece(node.guardedPattern.whenClause);
    var arrowPiece = tokenPiece(node.arrow);
    var bodyPiece = nodePiece(node.expression);

    pieces.add(CaseExpressionPiece(
        patternPiece, guardPiece, arrowPiece, bodyPiece,
        canBlockSplitPattern: node.guardedPattern.pattern.canBlockSplit,
        patternIsLogicalOr: node.guardedPattern.pattern is LogicalOrPattern,
        canBlockSplitBody: node.expression.canBlockSplit));
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    writeControlFlowStart(node.switchKeyword, node.leftParenthesis,
        node.expression, node.rightParenthesis);
    pieces.space();

    var sequence = SequenceBuilder(this);
    sequence.leftBracket(node.leftBracket);

    for (var member in node.members) {
      for (var label in member.labels) {
        sequence.visit(label);
      }

      sequence.addCommentsBefore(member.keyword);

      var casePiece = pieces.build(() {
        pieces.token(member.keyword);

        switch (member) {
          case SwitchCase():
            pieces.space();
            pieces.visit(member.expression);
          case SwitchPatternCase():
            pieces.space();

            var patternPiece = nodePiece(member.guardedPattern.pattern);

            if (member.guardedPattern.whenClause case var whenClause?) {
              pieces.add(
                  InfixPiece(const [], [patternPiece, nodePiece(whenClause)]));
            } else {
              pieces.add(patternPiece);
            }

          case SwitchDefault():
            break; // Nothing to do.
        }

        pieces.token(member.colon);
      });

      // Don't allow any blank lines between the `case` line and the first
      // statement in the case (or the next case if this case has no body).
      sequence.add(casePiece, indent: Indent.none, allowBlankAfter: false);

      for (var statement in member.statements) {
        sequence.visit(statement, indent: Indent.block);
      }
    }

    sequence.rightBracket(node.rightBracket);
    pieces.add(sequence.build());
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    pieces.token(node.poundSign);
    var components = node.components;
    for (var component in components) {
      // The '.' separator.
      if (component != components.first) {
        pieces.token(component.previous!);
      }

      pieces.token(component);
    }
  }

  @override
  void visitThisExpression(ThisExpression node) {
    pieces.token(node.thisKeyword);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    writePrefix(node.throwKeyword, space: true, node.expression);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    pieces.withMetadata(node.metadata, () {
      pieces.modifier(node.externalKeyword);
      pieces.visit(node.variables);
      pieces.token(node.semicolon);
    });
  }

  @override
  void visitTryStatement(TryStatement node) {
    writeTry(node);
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    writeTypeList(node.leftBracket, node.arguments, node.rightBracket);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    pieces.withMetadata(node.metadata, inlineMetadata: true, () {
      pieces.token(node.name);
      if (node.bound case var bound?) {
        pieces.space();
        pieces.token(node.extendsKeyword);
        pieces.space();
        pieces.visit(bound);
      }
    });
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    writeTypeList(node.leftBracket, node.typeParameters, node.rightBracket);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    throw UnsupportedError('This is handled by visitVariableDeclarationList()');
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    pieces.withMetadata(node.metadata,
        // If the variable is part of a for loop, it looks weird to force the
        // metadata to split since it's in a sort of expression-ish location:
        //
        //     for (@meta var x in list) ...
        inlineMetadata: _parentContext == NodeContext.forLoopVariable, () {
      var header = pieces.build(() {
        pieces.modifier(node.lateKeyword);
        pieces.modifier(node.keyword);
        pieces.visit(node.type);
      });

      var variables = <Piece>[];
      for (var variable in node.variables) {
        if ((variable.equals, variable.initializer)
            case (var equals?, var initializer?)) {
          var variablePiece = tokenPiece(variable.name);

          var equalsPiece = pieces.build(() {
            pieces.space();
            pieces.token(equals);
          });

          var initializerPiece = nodePiece(initializer,
              commaAfter: true, context: NodeContext.assignment);

          variables.add(AssignPiece(
              left: variablePiece,
              equalsPiece,
              initializerPiece,
              canBlockSplitRight: initializer.canBlockSplit));
        } else {
          variables.add(tokenPiece(variable.name, commaAfter: true));
        }
      }

      pieces.add(VariablePiece(header, variables, hasType: node.type != null));
    });
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    pieces.visit(node.variables);
    pieces.token(node.semicolon);
  }

  @override
  void visitWhenClause(WhenClause node) {
    writePrefix(node.whenKeyword, space: true, node.expression);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    var condition = pieces.build(() {
      writeControlFlowStart(node.whileKeyword, node.leftParenthesis,
          node.condition, node.rightParenthesis);
      pieces.space();
    });

    var body = nodePiece(node.body);

    var piece = ControlFlowPiece();
    piece.add(condition, body, isBlock: node.body is Block);
    pieces.add(piece);
  }

  @override
  void visitWildcardPattern(WildcardPattern node) {
    writePatternVariable(node.keyword, node.type, node.name);
  }

  @override
  void visitWithClause(WithClause node) {
    throw UnsupportedError(
        'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    pieces.token(node.yieldKeyword);
    pieces.token(node.star);
    pieces.space();
    pieces.visit(node.expression);
    pieces.token(node.semicolon);
  }

  /// Visits [node] in [context].
  @override
  void visitNode(AstNode node, NodeContext context) {
    var previousContext = _parentContext;
    _parentContext = context;

    node.accept(this);

    _parentContext = previousContext;
  }
}
