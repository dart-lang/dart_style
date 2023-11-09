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
import '../piece/block.dart';
import '../piece/chain.dart';
import '../piece/do_while.dart';
import '../piece/for.dart';
import '../piece/if.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/variable.dart';
import '../source_code.dart';
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
class AstNodeVisitor extends ThrowingAstVisitor<void>
    with CommentWriter, PieceFactory {
  /// Cached line info for calculating blank lines.
  @override
  final LineInfo lineInfo;

  @override
  final PieceWriter pieces;

  /// Create a new visitor that will be called to visit the code in [source].
  AstNodeVisitor(DartFormatter formatter, this.lineInfo, SourceCode source)
      : pieces = PieceWriter(formatter, source);

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

    pieces.give(sequence.build());

    // Finish writing and return the complete result.
    return pieces.finish();
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    throw UnimplementedError();
  }

  @override
  void visitAnnotation(Annotation node) {
    throw UnimplementedError();
  }

  @override
  void visitArgumentList(ArgumentList node, {bool nestExpression = true}) {
    throw UnimplementedError();
  }

  @override
  void visitAsExpression(AsExpression node) {
    createInfix(node.expression, node.asOperator, node.type);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    throw UnimplementedError();
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    visit(node.leftHandSide);
    space();
    finishAssignment(node.operator, node.rightHandSide);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    createInfixChain<BinaryExpression>(
        node,
        precedence: node.operator.type.precedence,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  void visitBlock(Block node) {
    createBlock(node);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    functionBodyModifiers(node);
    visit(node.block);
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    token(node.literal);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    createBreak(node.breakKeyword, node.label, node.semicolon);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitCastPattern(CastPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitCatchClause(CatchClause node) {
    throw UnimplementedError();
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    createType(
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
  void visitClassTypeAlias(ClassTypeAlias node) {
    createType(
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
  void visitComment(Comment node) {
    assert(false, 'Comments should be handled elsewhere.');
  }

  @override
  void visitCommentReference(CommentReference node) {
    assert(false, 'Comments should be handled elsewhere.');
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    assert(false, 'CompilationUnit should be handled directly by format().');
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    visit(node.condition);
    var condition = pieces.split();

    token(node.question);
    space();
    visit(node.thenExpression);
    var thenBranch = pieces.split();

    token(node.colon);
    space();
    visit(node.elseExpression);
    var elseBranch = pieces.take();

    var piece = InfixPiece([condition, thenBranch, elseBranch]);

    // If conditional expressions are directly nested, force them all to split,
    // both parents and children.
    if (node.parent is ConditionalExpression ||
        node.thenExpression is ConditionalExpression ||
        node.elseExpression is ConditionalExpression) {
      piece.pin(State.split);
    }

    pieces.give(piece);
  }

  @override
  void visitConfiguration(Configuration node) {
    token(node.ifKeyword);
    space();
    token(node.leftParenthesis);

    if (node.equalToken case var equals?) {
      createInfix(node.name, equals, node.value!, hanging: true);
    } else {
      visit(node.name);
    }

    token(node.rightParenthesis);
    space();
    visit(node.uri);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    if (node.constKeyword != null) throw UnimplementedError();
    visit(node.expression);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    throw UnimplementedError();
  }

  @override
  void visitConstructorName(ConstructorName node) {
    assert(false, 'This node is handled by visitInstanceCreationExpression().');
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    createBreak(node.continueKeyword, node.label, node.semicolon);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    modifier(node.keyword);
    visit(node.type, after: space);
    token(node.name);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    visit(node.parameter);

    if (node.separator case var separator?) {
      finishAssignment(separator, node.defaultValue!);
    }
  }

  @override
  void visitDoStatement(DoStatement node) {
    token(node.doKeyword);
    space();
    visit(node.body);
    space();
    token(node.whileKeyword);
    var body = pieces.split();

    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
    token(node.semicolon);
    var condition = pieces.take();

    pieces.give(DoWhilePiece(body, condition));
  }

  @override
  void visitDottedName(DottedName node) {
    createDotted(node.components);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    token(node.literal);
  }

  @override
  void visitEmptyFunctionBody(EmptyFunctionBody node) {
    token(node.semicolon);
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {
    token(node.semicolon);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitExportDirective(ExportDirective node) {
    createImport(node, node.exportKeyword);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    functionBodyModifiers(node);
    finishAssignment(node.functionDefinition, node.expression);
    token(node.semicolon);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    token(node.semicolon);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    assert(false, 'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    modifier(node.externalKeyword);
    modifier(node.staticKeyword);
    modifier(node.abstractKeyword);
    modifier(node.covariantKeyword);
    visit(node.fields);
    token(node.semicolon);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
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
    pieces.give(builder.build());
  }

  @override
  void visitForElement(ForElement node) {
    throw UnimplementedError();
  }

  @override
  void visitForStatement(ForStatement node) {
    modifier(node.awaitKeyword);
    token(node.forKeyword);
    var forKeyword = pieces.split();

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
        token(node.leftParenthesis);
        token(forParts.leftSeparator);
        token(forParts.rightSeparator);
        token(node.rightParenthesis);
        forPartsPiece = pieces.split();

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
          visit(initializer);
        } else {
          // No initializer, so look at the comments before `;`.
          partsList.addCommentsBefore(forParts.leftSeparator);
        }

        token(forParts.leftSeparator);
        partsList.add(pieces.split());

        // The condition clause.
        if (forParts.condition case var conditionExpression?) {
          partsList.addCommentsBefore(conditionExpression.beginToken);
          visit(conditionExpression);
        } else {
          partsList.addCommentsBefore(forParts.rightSeparator);
        }

        token(forParts.rightSeparator);
        partsList.add(pieces.split());

        // The update clauses.
        if (forParts.updaters.isNotEmpty) {
          partsList.addCommentsBefore(forParts.updaters.first.beginToken);
          createList(forParts.updaters,
              style: const ListStyle(commas: Commas.nonTrailing));
          partsList.add(pieces.split());
        }

        partsList.rightBracket(node.rightParenthesis);
        pieces.split();
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
        token(node.leftParenthesis);
        visit(variable);

        finishAssignment(forEachParts.inKeyword, forEachParts.iterable,
            splitBeforeOperator: true);
        token(node.rightParenthesis);
        forPartsPiece = pieces.split();

      case ForEachPartsWithPattern():
        throw UnimplementedError();
    }

    visit(node.body);
    var body = pieces.take();

    pieces.give(ForPiece(forKeyword, forPartsPiece, body,
        hasBlockBody: node.body is Block));
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitForPartsWithExpression(ForPartsWithExpression node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitForPartsWithPattern(ForPartsWithPattern node) {
    assert(false, 'This node is handled by visitForStatement().');
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    createFunction(
        externalKeyword: node.externalKeyword,
        returnType: node.returnType,
        propertyKeyword: node.propertyKeyword,
        name: node.name,
        typeParameters: node.functionExpression.typeParameters,
        parameters: node.functionExpression.parameters,
        body: node.functionExpression.body);
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    visit(node.functionDeclaration);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    finishFunction(null, node.typeParameters, node.parameters, node.body);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    startFormalParameter(node);
    createFunctionType(node.returnType, node.name, node.typeParameters,
        node.parameters, node.question);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    createFunctionType(node.returnType, node.functionKeyword,
        node.typeParameters, node.parameters, node.question);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  void visitHideCombinator(HideCombinator node) {
    assert(false, 'Combinators are handled by createImport().');
  }

  @override
  void visitIfElement(IfElement node) {
    throw UnimplementedError();
  }

  @override
  void visitIfStatement(IfStatement node) {
    createIf(node);
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    assert(false, 'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitImportDirective(ImportDirective node) {
    createImport(node, node.importKeyword,
        deferredKeyword: node.deferredKeyword,
        asKeyword: node.asKeyword,
        prefix: node.prefix);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    token(node.keyword, after: space);

    // If there is an import prefix and/or constructor name, then allow
    // splitting before the `.`. This doesn't look good, but is consistent with
    // constructor calls that don't have `new` or `const`. We allow splitting
    // in the latter because there is no way to distinguish syntactically
    // between a named constructor call and any other kind of method call or
    // property access.
    var operations = <Piece>[];

    var constructor = node.constructorName;
    if (constructor.type.importPrefix case var importPrefix?) {
      token(importPrefix.name);
      operations.add(pieces.split());
      token(importPrefix.period);
    }

    // The name of the type being constructed.
    var type = constructor.type;
    token(type.name2);
    visit(type.typeArguments);
    token(type.question);

    // If this is a named constructor call, the name.
    if (constructor.name != null) {
      operations.add(pieces.split());
      token(constructor.period);
      visit(constructor.name);
    }

    finishCall(node.argumentList);

    // If there was a prefix or constructor name, then make a splittable piece.
    if (operations.isNotEmpty) {
      operations.add(pieces.take());
      pieces.give(ChainPiece(operations));
    }
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    token(node.literal);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    throw UnimplementedError();
  }

  @override
  void visitIsExpression(IsExpression node) {
    createInfix(
        node.expression,
        node.isOperator,
        operator2: node.notOperator,
        node.type);
  }

  @override
  void visitLabel(Label node) {
    visit(node.label);
    token(node.colon);
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    var sequence = SequenceBuilder(this);
    for (var label in node.labels) {
      sequence.visit(label);
    }

    sequence.visit(node.statement);
    pieces.give(sequence.build());
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    createDirectiveMetadata(node);
    token(node.libraryKeyword);
    visit(node.name2, before: space);
    token(node.semicolon);
  }

  @override
  void visitLibraryIdentifier(LibraryIdentifier node) {
    createDotted(node.components);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    createCollection(
      node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  void visitListPattern(ListPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitLogicalAndPattern(LogicalAndPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitLogicalOrPattern(LogicalOrPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    visit(node.key);
    finishAssignment(node.separator, node.value);
  }

  @override
  void visitMapPattern(MapPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    throw UnimplementedError();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    createFunction(
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
  void visitMethodInvocation(MethodInvocation node) {
    // TODO(tall): Support method invocation with explicit target expressions.
    if (node.target != null) throw UnimplementedError();

    visit(node.methodName);
    visit(node.typeArguments);
    finishCall(node.argumentList);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    createType(node.metadata, [node.baseKeyword], node.mixinKeyword, node.name,
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
  void visitNamedExpression(NamedExpression node) {
    visit(node.name.label);
    finishAssignment(node.name.colon, node.expression);
  }

  @override
  void visitNamedType(NamedType node) {
    if (node.importPrefix case var importPrefix?) {
      token(importPrefix.name);
      token(importPrefix.period);
    }

    token(node.name2);
    visit(node.typeArguments);
    token(node.question);
  }

  @override
  void visitNativeClause(NativeClause node) {
    space();
    token(node.nativeKeyword);
    space();
    visit(node.name);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitNullCheckPattern(NullCheckPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    token(node.literal);
  }

  @override
  void visitObjectPattern(ObjectPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitOnClause(OnClause node) {
    assert(false, 'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    token(node.leftParenthesis);
    visit(node.expression);
    token(node.rightParenthesis);
  }

  @override
  void visitParenthesizedPattern(ParenthesizedPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitPartDirective(PartDirective node) {
    createDirectiveMetadata(node);
    token(node.partKeyword);
    space();
    visit(node.uri);
    token(node.semicolon);
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    createDirectiveMetadata(node);
    token(node.partKeyword);
    space();
    token(node.ofKeyword);
    space();

    // Part-of may have either a name or a URI. Only one of these will be
    // non-null. We visit both since visit() ignores null.
    visit(node.libraryName);
    visit(node.uri);
    token(node.semicolon);
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternField(PatternField node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    throw UnimplementedError();
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    token(node.operator);

    // Edge case: put a space after "-" if the operand is "-" or "--" so that
    // we don't merge the operator tokens.
    if (node.operand
        case PrefixExpression(operator: Token(lexeme: '-' || '--'))) {
      space();
    }

    visit(node.operand);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    throw UnimplementedError();
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    ListStyle style;
    if (node.fields.length == 1 && node.fields[0] is! NamedExpression) {
      // Single-element records always have a trailing comma, unless the single
      // element is a named field.
      style = const ListStyle(commas: Commas.alwaysTrailing);
    } else {
      style = const ListStyle(commas: Commas.trailing);
    }
    createCollection(
      node.constKeyword,
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
      style: style,
    );
  }

  @override
  void visitRecordPattern(RecordPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    throw UnimplementedError();
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitRestPatternElement(RestPatternElement node) {
    throw UnimplementedError();
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    token(node.returnKeyword);

    if (node.expression case var expression) {
      space();
      visit(expression);
    }

    token(node.semicolon);
  }

  @override
  void visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it.
    pieces.writeText(node.scriptTag.lexeme.trim(),
        offset: node.scriptTag.offset);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    createCollection(
      node.constKeyword,
      typeArguments: node.typeArguments,
      node.leftBracket,
      node.elements,
      node.rightBracket,
    );
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    assert(false, 'Combinators are handled by createImport().');
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    startFormalParameter(node);

    if ((node.type, node.name) case (var type?, var name?)) {
      // Have both a type and name, so allow splitting between them.
      modifier(node.keyword);
      visit(type);
      var typePiece = pieces.split();

      token(name);
      var namePiece = pieces.take();

      pieces.give(VariablePiece(typePiece, [namePiece], hasType: true));
    } else {
      // Only one of name or type so just write whichever there is.
      modifier(node.keyword);
      visit(node.type);
      token(node.name);
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    token(node.literal);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    throw UnimplementedError();
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    var list = DelimitedListBuilder(this,
        const ListStyle(spaceWhenUnsplit: true, splitListIfBeforeSplits: true));

    createSwitchValue(node.switchKeyword, node.leftParenthesis, node.expression,
        node.rightParenthesis);
    space();
    list.leftBracket(node.leftBracket);

    for (var member in node.cases) {
      list.visit(member);
    }

    list.rightBracket(node.rightBracket);
    pieces.give(list.build());
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    if (node.guardedPattern.whenClause != null) throw UnimplementedError();

    visit(node.guardedPattern.pattern);
    space();
    finishAssignment(node.arrow, node.expression);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    createSwitchValue(node.switchKeyword, node.leftParenthesis, node.expression,
        node.rightParenthesis);

    // Attach the ` {` after the `)` in the [ListPiece] created by
    // [createSwitchValue()].
    space();
    token(node.leftBracket);
    var switchPiece = pieces.split();

    var sequence = SequenceBuilder(this);
    for (var member in node.members) {
      for (var label in member.labels) {
        sequence.visit(label);
      }

      sequence.addCommentsBefore(member.keyword);
      token(member.keyword);

      if (member is SwitchCase) {
        space();
        visit(member.expression);
      } else if (member is SwitchPatternCase) {
        space();

        if (member.guardedPattern.whenClause != null) {
          throw UnimplementedError();
        }

        visit(member.guardedPattern.pattern);
      } else {
        assert(member is SwitchDefault);
        // Nothing to do.
      }

      token(member.colon);
      var casePiece = pieces.split();

      // Don't allow any blank lines between the `case` line and the first
      // statement in the case (or the next case if this case has no body).
      sequence.add(casePiece, indent: Indent.none, allowBlankAfter: false);

      for (var statement in member.statements) {
        sequence.visit(statement, indent: Indent.block);
      }
    }

    // Place any comments before the "}" inside the sequence.
    sequence.addCommentsBefore(node.rightBracket);

    token(node.rightBracket);
    var rightBracketPiece = pieces.take();

    pieces.give(BlockPiece(switchPiece, sequence.build(), rightBracketPiece,
        alwaysSplit: node.members.isNotEmpty));
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    token(node.poundSign);
    var components = node.components;
    for (var component in components) {
      // The '.' separator.
      if (component != components.first) token(component.previous);
      token(component);
    }
  }

  @override
  void visitThisExpression(ThisExpression node) {
    token(node.thisKeyword);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    modifier(node.externalKeyword);
    visit(node.variables);
    token(node.semicolon);
  }

  @override
  void visitTryStatement(TryStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    createTypeList(node.leftBracket, node.arguments, node.rightBracket);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    token(node.name);
    if (node.bound case var bound?) {
      space();
      modifier(node.extendsKeyword);
      visit(bound);
    }
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    createTypeList(node.leftBracket, node.typeParameters, node.rightBracket);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    token(node.name);
    if ((node.equals, node.initializer) case (var equals?, var initializer?)) {
      finishAssignment(equals, initializer);
    }
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    // TODO(tall): Format metadata.
    if (node.metadata.isNotEmpty) throw UnimplementedError();

    modifier(node.lateKeyword);
    modifier(node.keyword);

    // TODO(tall): Test how splits inside the type annotation (like in a type
    // argument list or a function type's parameter list) affect the indentation
    // and splitting of the surrounding variable declaration.
    visit(node.type);
    var header = pieces.take();

    var variables = <Piece>[];
    for (var variable in node.variables) {
      pieces.split();
      visit(variable);
      commaAfter(variable);
      variables.add(pieces.take());
    }

    pieces.give(VariablePiece(header, variables, hasType: node.type != null));
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    visit(node.variables);
    token(node.semicolon);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    token(node.whileKeyword);
    space();
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
    var condition = pieces.split();

    visit(node.body);
    var body = pieces.take();

    var piece = IfPiece();
    piece.add(condition, body, isBlock: node.body is Block);
    pieces.give(piece);
  }

  @override
  void visitWildcardPattern(WildcardPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitWithClause(WithClause node) {
    assert(false, 'This node is handled by PieceFactory.createType().');
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    token(node.yieldKeyword);
    token(node.star);
    space();
    visit(node.expression);
    token(node.semicolon);
  }

  /// If [node] is not `null`, then visit it.
  ///
  /// Invokes [before] before visiting [node], and [after] afterwards, but only
  /// if [node] is present.
  @override
  void visit(AstNode? node, {void Function()? before, void Function()? after}) {
    if (node == null) return;

    if (before != null) before();
    node.accept(this);
    if (after != null) after();
  }
}
