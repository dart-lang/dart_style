// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.source_visitor;

import 'dart:math';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'formatter.dart';
import 'source_writer.dart';
import 'line.dart';

/// Used for matching EOL comments
final twoSlashes = new RegExp(r'//[^/]');

/// An AST visitor that drives formatting heuristics.
class SourceVisitor implements AstVisitor {
  /// The writer to which the source is to be written.
  final SourceWriter writer;

  /// Cached line info for calculating blank lines.
  LineInfo lineInfo;

  /// Cached previous token for calculating preceding whitespace.
  Token previousToken;

  /// A flag to indicate that a newline should be emitted before the next token.
  bool needsNewline = false;

  /// A flag to indicate that user introduced newlines should be emitted before
  /// the next token.
  bool preserveNewlines = false;

  /// A counter for spaces that should be emitted preceding the next token.
  int leadingSpaces = 0;

  /// A flag to specify whether line-leading spaces should be preserved (and
  /// addded to the indent level).
  bool allowLineLeadingSpaces;

  /// A flag to specify whether zero-length spaces should be emmitted.
  bool emitEmptySpaces = false;

  /// A weight for potential breakpoints.
  int currentBreakWeight = DEFAULT_SPACE_WEIGHT;

  /// The last issued space weight.
  int lastSpaceWeight = 0;

  /// Original pre-format selection information (may be null).
  final Selection preSelection;

  /// The source being formatted (used in interpolation handling)
  final String source;

  /// Post format selection information.
  Selection selection;

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(FormatterOptions options, this.lineInfo, this.source,
    this.preSelection)
      : writer = new SourceWriter(indentCount: options.initialIndentationLevel,
                                lineSeparator: options.lineSeparator,
                                maxLineLength: options.pageWidth);

  visitAdjacentStrings(AdjacentStrings node) {
    visitNodes(node.strings, separatedBy: space);
  }

  visitAnnotation(Annotation node) {
    token(node.atSign);
    visit(node.name);
    token(node.period);
    visit(node.constructorName);
    visit(node.arguments);
  }

  visitArgumentList(ArgumentList node) {
    token(node.leftParenthesis);
    if (node.arguments.isNotEmpty) {
      int weight = lastSpaceWeight++;
      levelSpace(weight, 0);
      visitCommaSeparatedNodes(
          node.arguments,
          followedBy: () => levelSpace(weight));
    }
    token(node.rightParenthesis);
  }

  visitAsExpression(AsExpression node) {
    visit(node.expression);
    space();
    token(node.asOperator);
    space();
    visit(node.type);
  }

  visitAssertStatement(AssertStatement node) {
    token(node.keyword);
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
    token(node.semicolon);
  }

  visitAssignmentExpression(AssignmentExpression node) {
    visit(node.leftHandSide);
    space();
    token(node.operator);
    allowContinuedLines(() {
      levelSpace(SINGLE_SPACE_WEIGHT);
      visit(node.rightHandSide);
    });
  }

  @override
  visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  visitBinaryExpression(BinaryExpression node) {
    Token operator = node.operator;
    TokenType operatorType = operator.type;
    int addOperands(List<Expression> operands, Expression e, int i) {
      if (e is BinaryExpression && e.operator.type == operatorType) {
        i = addOperands(operands, e.leftOperand, i);
        i = addOperands(operands, e.rightOperand, i);
      } else {
        operands.insert(i++, e);
      }
      return i;
    }
    List<Expression> operands = [];
    addOperands(operands, node.leftOperand, 0);
    addOperands(operands, node.rightOperand, operands.length);
    int weight = lastSpaceWeight++;
    for (int i = 0; i < operands.length; i++) {
      if (i != 0) {
        space();
        token(operator);
        levelSpace(weight);
      }
      visit(operands[i]);
    }
  }

  visitBlock(Block node) {
    token(node.leftBracket);
    indent();
    if (!node.statements.isEmpty) {
      visitNodes(node.statements, precededBy: newlines, separatedBy: newlines);
      newlines();
    } else {
      preserveLeadingNewlines();
    }
    token(node.rightBracket, precededBy: unindent);
  }

  visitBlockFunctionBody(BlockFunctionBody node) {
    // The "async" or "sync" keyword.
    if (node.keyword != null) {
      token(node.keyword);
      space();
    }

    visit(node.block);
  }

  visitBooleanLiteral(BooleanLiteral node) {
    token(node.literal);
  }

  visitBreakStatement(BreakStatement node) {
    token(node.keyword);
    visitNode(node.label, precededBy: space);
    token(node.semicolon);
  }

  visitCascadeExpression(CascadeExpression node) {
    visit(node.target);
    indent(2);
    // Single cascades do not force a linebreak (dartbug.com/16384)
    if (node.cascadeSections.length > 1) {
      newlines();
    }
    visitNodes(node.cascadeSections, separatedBy: newlines);
    unindent(2);
  }

  visitCatchClause(CatchClause node) {

    token(node.onKeyword, followedBy: space);
    visit(node.exceptionType);

    if (node.catchKeyword != null) {
      if (node.exceptionType != null) {
        space();
      }
      token(node.catchKeyword);
      space();
      token(node.leftParenthesis);
      visit(node.exceptionParameter);
      token(node.comma, followedBy: space);
      visit(node.stackTraceParameter);
      token(node.rightParenthesis);
      space();
    } else {
      space();
    }
    visit(node.body);
  }

  visitClassDeclaration(ClassDeclaration node) {
    preserveLeadingNewlines();
    visitMemberMetadata(node.metadata);
    modifier(node.abstractKeyword);
    token(node.classKeyword);
    space();
    visit(node.name);
    allowContinuedLines(() {
      visit(node.typeParameters);
      visitNode(node.extendsClause, precededBy: space);
      visitNode(node.withClause, precededBy: space);
      visitNode(node.implementsClause, precededBy: space);
      visitNode(node.nativeClause, precededBy: space);
      space();
    });
    token(node.leftBracket);
    indent();
    if (!node.members.isEmpty) {
      visitNodes(node.members, precededBy: newlines, separatedBy: newlines);
      newlines();
    } else {
      preserveLeadingNewlines();
    }
    token(node.rightBracket, precededBy: unindent);
  }

  visitClassTypeAlias(ClassTypeAlias node) {
    preserveLeadingNewlines();
    visitMemberMetadata(node.metadata);
    modifier(node.abstractKeyword);
    token(node.keyword);
    space();
    visit(node.name);
    visit(node.typeParameters);
    space();
    token(node.equals);
    space();
    visit(node.superclass);
    visitNode(node.withClause, precededBy: space);
    visitNode(node.implementsClause, precededBy: space);
    token(node.semicolon);
  }

  visitComment(Comment node) => null;

  visitCommentReference(CommentReference node) => null;

  visitCompilationUnit(CompilationUnit node) {
    // Cache EOF for leading whitespace calculation.
    var start = node.beginToken.previous;
    if (start != null && start.type is TokenType_EOF) {
      previousToken = start;
    }

    var scriptTag = node.scriptTag;
    var directives = node.directives;
    visit(scriptTag);

    visitNodes(directives, separatedBy: newlines, followedBy: newlines);

    visitNodes(node.declarations, separatedBy: newlines);

    preserveLeadingNewlines();

    // Handle trailing whitespace.
    token(node.endToken /* EOF */);

    // Be a good citizen, end with a newline.
    ensureTrailingNewline();
  }

  visitConditionalExpression(ConditionalExpression node) {
    int weight = lastSpaceWeight++;
    visit(node.condition);
    space();
    token(node.question);
    allowContinuedLines(() {
      levelSpace(weight);
      visit(node.thenExpression);
      space();
      token(node.colon);
      levelSpace(weight);
      visit(node.elseExpression);
    });
  }

  visitConstructorDeclaration(ConstructorDeclaration node) {
    visitMemberMetadata(node.metadata);
    modifier(node.externalKeyword);
    modifier(node.constKeyword);
    modifier(node.factoryKeyword);
    visit(node.returnType);
    token(node.period);
    visit(node.name);
    visit(node.parameters);

    // Check for redirects or initializer lists
    if (node.separator != null) {
      if (node.redirectedConstructor != null) {
        visitConstructorRedirects(node);
      } else {
        visitConstructorInitializers(node);
      }
    }

    var body = node.body;
    visitPrefixedBody(space, body);
  }

  visitConstructorInitializers(ConstructorDeclaration node) {
    if (node.initializers.length > 1) {
      newlines();
    } else {
      preserveLeadingNewlines();
      levelSpace(lastSpaceWeight++);
    }
    indent(2);
    token(node.separator /* : */);
    space();
    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // preceding comma
        token(node.initializers[i].beginToken.previous);
        newlines();
        space(n: 2, allowLineLeading: true);
      }
      node.initializers[i].accept(this);
    }
    unindent(2);
  }

  visitConstructorRedirects(ConstructorDeclaration node) {
    token(node.separator /* = */, precededBy: space, followedBy: space);
    visitCommaSeparatedNodes(node.initializers);
    visit(node.redirectedConstructor);
  }

  visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    token(node.keyword);
    token(node.period);
    visit(node.fieldName);
    space();
    token(node.equals);
    space();
    visit(node.expression);
  }

  visitConstructorName(ConstructorName node) {
    visit(node.type);
    token(node.period);
    visit(node.name);
  }

  visitContinueStatement(ContinueStatement node) {
    token(node.keyword);
    visitNode(node.label, precededBy: space);
    token(node.semicolon);
  }

  visitDeclaredIdentifier(DeclaredIdentifier node) {
    modifier(node.keyword);
    visitNode(node.type, followedBy: space);
    visit(node.identifier);
  }

  visitDefaultFormalParameter(DefaultFormalParameter node) {
    visit(node.parameter);
    if (node.separator != null) {
      // The '=' separator is preceded by a space.
      if (node.separator.type == TokenType.EQ) {
        space();
      }
      token(node.separator);
      visitNode(node.defaultValue, precededBy: space);
    }
  }

  visitDoStatement(DoStatement node) {
    token(node.doKeyword);
    space();
    visit(node.body);
    space();
    token(node.whileKeyword);
    space();
    token(node.leftParenthesis);
    allowContinuedLines(() {
      visit(node.condition);
      token(node.rightParenthesis);
    });
    token(node.semicolon);
  }

  visitDoubleLiteral(DoubleLiteral node) {
    token(node.literal);
  }

  visitEmptyFunctionBody(EmptyFunctionBody node) {
    token(node.semicolon);
  }

  visitEmptyStatement(EmptyStatement node) {
    token(node.semicolon);
  }

  visitExportDirective(ExportDirective node) {
    visitDirectiveMetadata(node.metadata);
    token(node.keyword);
    space();
    visit(node.uri);
    allowContinuedLines(() {
      visitNodes(node.combinators, precededBy: space, separatedBy: space);
    });
    token(node.semicolon);
  }

  visitExpressionFunctionBody(ExpressionFunctionBody node) {
    // The "async" or "sync" keyword.
    if (node.keyword != null) {
      token(node.keyword);
      space();
    }

    int weight = lastSpaceWeight++;
    token(node.functionDefinition);

    levelSpace(weight);
    visit(node.expression);
    token(node.semicolon);
  }

  visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    token(node.semicolon);
  }

  visitExtendsClause(ExtendsClause node) {
    token(node.keyword);
    space();
    visit(node.superclass);
  }

  visitFieldDeclaration(FieldDeclaration node) {
    visitMemberMetadata(node.metadata);
    modifier(node.staticKeyword);
    visit(node.fields);
    token(node.semicolon);
  }

  visitFieldFormalParameter(FieldFormalParameter node) {
    token(node.keyword, followedBy: space);
    visitNode(node.type, followedBy: space);
    token(node.thisToken);
    token(node.period);
    visit(node.identifier);
    visit(node.parameters);
  }

  visitForEachStatement(ForEachStatement node) {
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);
    if (node.loopVariable != null) {
      visit(node.loopVariable);
    } else {
      visit(node.identifier);
    }
    space();
    token(node.inKeyword);
    space();
    visit(node.iterator);
    token(node.rightParenthesis);
    space();
    visit(node.body);
  }

  visitFormalParameterList(FormalParameterList node) {
    var groupEnd = null;
    token(node.leftParenthesis);
    var parameters = node.parameters;
    var size = parameters.length;
    for (var i = 0; i < size; i++) {
      var parameter = parameters[i];
      if (i > 0) {
        append(',');
        space();
      }
      if (groupEnd == null && parameter is DefaultFormalParameter) {
        if (identical(parameter.kind, ParameterKind.NAMED)) {
          groupEnd = '}';
          append('{');
        } else {
          groupEnd = ']';
          append('[');
        }
      }
      parameter.accept(this);
    }
    if (groupEnd != null) {
      append(groupEnd);
    }
    token(node.rightParenthesis);
  }

  visitForStatement(ForStatement node) {
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);
    if (node.initialization != null) {
      visit(node.initialization);
    } else {
      if (node.variables == null) {
        space();
      } else {
        visit(node.variables);
      }
    }
    token(node.leftSeparator);
    space();
    visit(node.condition);
    token(node.rightSeparator);
    if (node.updaters != null) {
      space();
      visitCommaSeparatedNodes(node.updaters);
    }
    token(node.rightParenthesis);
    if (node.body is! EmptyStatement) {
      space();
    }
    visit(node.body);
  }

  visitFunctionDeclaration(FunctionDeclaration node) {
    preserveLeadingNewlines();
    visitMemberMetadata(node.metadata);
    modifier(node.externalKeyword);
    visitNode(node.returnType, followedBy: space);
    modifier(node.propertyKeyword);
    visit(node.name);
    visit(node.functionExpression);
  }

  visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    visit(node.functionDeclaration);
  }

  visitFunctionExpression(FunctionExpression node) {
    visit(node.parameters);
    if (node.body is! EmptyFunctionBody) {
      space();
    }
    visit(node.body);
  }

  visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    visit(node.function);
    visit(node.argumentList);
  }

  visitFunctionTypeAlias(FunctionTypeAlias node) {
    visitMemberMetadata(node.metadata);
    token(node.keyword);
    space();
    visitNode(node.returnType, followedBy: space);
    visit(node.name);
    visit(node.typeParameters);
    visit(node.parameters);
    token(node.semicolon);
  }

  visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    visitNode(node.returnType, followedBy: space);
    visit(node.identifier);
    visit(node.parameters);
  }

  visitHideCombinator(HideCombinator node) {
    token(node.keyword);
    space();
    visitCommaSeparatedNodes(node.hiddenNames);
  }

  visitIfStatement(IfStatement node) {
    var hasElse = node.elseStatement != null;
    token(node.ifKeyword);
    allowContinuedLines(() {
      space();
      token(node.leftParenthesis);
      visit(node.condition);
      token(node.rightParenthesis);
    });
    space();
    if (hasElse) {
      visit(node.thenStatement);
      space();
      token(node.elseKeyword);
      space();
      if (node.elseStatement is IfStatement) {
        visit(node.elseStatement);
      } else {
        visit(node.elseStatement);
      }
    } else {
      visit(node.thenStatement);
    }
  }

  visitImplementsClause(ImplementsClause node) {
    token(node.keyword);
    space();
    visitCommaSeparatedNodes(node.interfaces);
  }

  visitImportDirective(ImportDirective node) {
    visitDirectiveMetadata(node.metadata);
    token(node.keyword);
    nonBreakingSpace();
    visit(node.uri);
    token(node.deferredToken, precededBy: space);
    token(node.asToken, precededBy: space, followedBy: space);
    allowContinuedLines(() {
      visit(node.prefix);
      visitNodes(node.combinators, precededBy: space, separatedBy: space);
    });
    token(node.semicolon);
  }

  visitIndexExpression(IndexExpression node) {
    if (node.isCascaded) {
      token(node.period);
    } else {
      visit(node.target);
    }
    token(node.leftBracket);
    visit(node.index);
    token(node.rightBracket);
  }

  visitInstanceCreationExpression(InstanceCreationExpression node) {
    token(node.keyword);
    nonBreakingSpace();
    visit(node.constructorName);
    visit(node.argumentList);
  }

  visitIntegerLiteral(IntegerLiteral node) {
    token(node.literal);
  }

  visitInterpolationExpression(InterpolationExpression node) {
    if (node.rightBracket != null) {
      token(node.leftBracket);
      visit(node.expression);
      token(node.rightBracket);
    } else {
      token(node.leftBracket);
      visit(node.expression);
    }
  }

  visitInterpolationString(InterpolationString node) {
    token(node.contents);
  }

  visitIsExpression(IsExpression node) {
    visit(node.expression);
    space();
    token(node.isOperator);
    token(node.notOperator);
    space();
    visit(node.type);
  }

  visitLabel(Label node) {
    visit(node.label);
    token(node.colon);
  }

  visitLabeledStatement(LabeledStatement node) {
    visitNodes(node.labels, separatedBy: space, followedBy: space);
    visit(node.statement);
  }

  visitLibraryDirective(LibraryDirective node) {
    visitDirectiveMetadata(node.metadata);
    token(node.keyword);
    space();
    visit(node.name);
    token(node.semicolon);
  }

  visitLibraryIdentifier(LibraryIdentifier node) {
    append(node.name);
  }

  visitListLiteral(ListLiteral node) {
    int weight = lastSpaceWeight++;
    modifier(node.constKeyword);
    visit(node.typeArguments);
    token(node.leftBracket);
    indent();
    levelSpace(weight, 0);
    visitCommaSeparatedNodes(
        node.elements,
        followedBy: () => levelSpace(weight));
    optionalTrailingComma(node.rightBracket);
    token(node.rightBracket, precededBy: unindent);
  }

  visitMapLiteral(MapLiteral node) {
    modifier(node.constKeyword);
    visitNode(node.typeArguments);
    token(node.leftBracket);
    if (!node.entries.isEmpty) {
      newlines();
      indent();
      visitCommaSeparatedNodes(node.entries, followedBy: newlines);
      optionalTrailingComma(node.rightBracket);
      unindent();
      newlines();
    }
    token(node.rightBracket);
  }

  visitMapLiteralEntry(MapLiteralEntry node) {
    visit(node.key);
    token(node.separator);
    space();
    visit(node.value);
  }

  visitMethodDeclaration(MethodDeclaration node) {
    visitMemberMetadata(node.metadata);
    modifier(node.externalKeyword);
    modifier(node.modifierKeyword);
    visitNode(node.returnType, followedBy: space);
    modifier(node.propertyKeyword);
    modifier(node.operatorKeyword);
    visit(node.name);
    if (!node.isGetter) {
      visit(node.parameters);
    }
    visitPrefixedBody(nonBreakingSpace, node.body);
  }

  visitMethodInvocation(MethodInvocation node) {
    visit(node.target);
    token(node.period);
    visit(node.methodName);
    visit(node.argumentList);
  }

  visitNamedExpression(NamedExpression node) {
    visit(node.name);
    visitNode(node.expression, precededBy: space);
  }

  visitNativeClause(NativeClause node) {
    token(node.keyword);
    space();
    visit(node.name);
  }

  visitNativeFunctionBody(NativeFunctionBody node) {
    token(node.nativeToken);
    space();
    visit(node.stringLiteral);
    token(node.semicolon);
  }

  visitNullLiteral(NullLiteral node) {
    token(node.literal);
  }

  visitParenthesizedExpression(ParenthesizedExpression node) {
    token(node.leftParenthesis);
    visit(node.expression);
    token(node.rightParenthesis);
  }

  visitPartDirective(PartDirective node) {
    token(node.keyword);
    space();
    visit(node.uri);
    token(node.semicolon);
  }

  visitPartOfDirective(PartOfDirective node) {
    token(node.keyword);
    space();
    token(node.ofToken);
    space();
    visit(node.libraryName);
    token(node.semicolon);
  }

  visitPostfixExpression(PostfixExpression node) {
    visit(node.operand);
    token(node.operator);
  }

  visitPrefixedIdentifier(PrefixedIdentifier node) {
    visit(node.prefix);
    token(node.period);
    visit(node.identifier);
  }

  visitPrefixExpression(PrefixExpression node) {
    token(node.operator);
    visit(node.operand);
  }

  visitPropertyAccess(PropertyAccess node) {
    if (node.isCascaded) {
      token(node.operator);
    } else {
      visit(node.target);
      token(node.operator);
    }
    visit(node.propertyName);
  }

  visitRedirectingConstructorInvocation(RedirectingConstructorInvocation node) {
    token(node.keyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);
  }

  visitRethrowExpression(RethrowExpression node) {
    token(node.keyword);
  }

  visitReturnStatement(ReturnStatement node) {
    var expression = node.expression;
    if (expression == null) {
      token(node.keyword);
      token(node.semicolon);
    } else {
      token(node.keyword);
      allowContinuedLines(() {
        space();
        expression.accept(this);
        token(node.semicolon);
      });
    }
  }

  visitScriptTag(ScriptTag node) {
    token(node.scriptTag);
  }

  visitShowCombinator(ShowCombinator node) {
    token(node.keyword);
    space();
    visitCommaSeparatedNodes(node.shownNames);
  }

  visitSimpleFormalParameter(SimpleFormalParameter node) {
    visitMemberMetadata(node.metadata);
    modifier(node.keyword);
    visitNode(node.type, followedBy: nonBreakingSpace);
    visit(node.identifier);
  }

  visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  visitSimpleStringLiteral(SimpleStringLiteral node) {
    token(node.literal);
  }

  visitStringInterpolation(StringInterpolation node) {
    // Ensure that interpolated strings don't get broken up by treating them as
    // a single String token
    // Process token (for comments etc. but don't print the lexeme)
    token(node.beginToken, printToken: (tok) => null);
    var start = node.beginToken.offset;
    var end = node.endToken.end;
    String string = source.substring(start, end);
    append(string);
    //visitNodes(node.elements);
  }

  visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    token(node.keyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);
  }

  visitSuperExpression(SuperExpression node) {
    token(node.keyword);
  }

  visitSwitchCase(SwitchCase node) {
    visitNodes(node.labels, separatedBy: space, followedBy: space);
    token(node.keyword);
    space();
    visit(node.expression);
    token(node.colon);
    newlines();
    indent();
    visitNodes(node.statements, separatedBy: newlines);
    unindent();
  }

  visitSwitchDefault(SwitchDefault node) {
    visitNodes(node.labels, separatedBy: space, followedBy: space);
    token(node.keyword);
    token(node.colon);
    newlines();
    indent();
    visitNodes(node.statements, separatedBy: newlines);
    unindent();
  }

  visitSwitchStatement(SwitchStatement node) {
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    visit(node.expression);
    token(node.rightParenthesis);
    space();
    token(node.leftBracket);
    indent();
    newlines();
    visitNodes(node.members, separatedBy: newlines, followedBy: newlines);
    token(node.rightBracket, precededBy: unindent);

  }

  visitSymbolLiteral(SymbolLiteral node) {
    token(node.poundSign);
    var components = node.components;
    var size = components.length;
    for (var component in components) {
      // The '.' separator
      if (component.previous.lexeme == '.') {
        token(component.previous);
      }
      token(component);
    }
  }

  visitThisExpression(ThisExpression node) {
    token(node.keyword);
  }

  visitThrowExpression(ThrowExpression node) {
    token(node.keyword);
    space();
    visit(node.expression);
  }

  visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    visit(node.variables);
    token(node.semicolon);
  }

  visitTryStatement(TryStatement node) {
    token(node.tryKeyword);
    space();
    visit(node.body);
    visitNodes(node.catchClauses, precededBy: space, separatedBy: space);
    token(node.finallyKeyword, precededBy: space, followedBy: space);
    visit(node.finallyBlock);
  }

  visitTypeArgumentList(TypeArgumentList node) {
    token(node.leftBracket);
    visitCommaSeparatedNodes(node.arguments);
    token(node.rightBracket);
  }

  visitTypeName(TypeName node) {
    visit(node.name);
    visit(node.typeArguments);
  }

  visitTypeParameter(TypeParameter node) {
    visitMemberMetadata(node.metadata);
    visit(node.name);
    token(node.keyword /* extends */, precededBy: space, followedBy: space);
    visit(node.bound);
  }

  visitTypeParameterList(TypeParameterList node) {
    token(node.leftBracket);
    visitCommaSeparatedNodes(node.typeParameters);
    token(node.rightBracket);
  }

  visitVariableDeclaration(VariableDeclaration node) {
    visit(node.name);
    if (node.initializer != null) {
      space();
      token(node.equals);
      var initializer = node.initializer;
      if (initializer is ListLiteral || initializer is MapLiteral) {
        space();
        visit(initializer);
      } else if (initializer is BinaryExpression) {
        allowContinuedLines(() {
          levelSpace(lastSpaceWeight);
          visit(initializer);
        });
      } else {
        allowContinuedLines(() {
          levelSpace(SINGLE_SPACE_WEIGHT);
          visit(initializer);
        });
      }
    }
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    visitMemberMetadata(node.metadata);
    modifier(node.keyword);
    visitNode(node.type, followedBy: space);

    var variables = node.variables;
    // Decls with initializers get their own lines (dartbug.com/16849)
    if (variables.any((v) => (v.initializer != null))) {
      var size = variables.length;
      if (size > 0) {
        var variable;
        for (var i = 0; i < size; i++) {
          variable = variables[i];
          if (i > 0) {
            var comma = variable.beginToken.previous;
            token(comma);
            newlines();
          }
          if (i == 1) {
            indent(2);
          }
          variable.accept(this);
        }
        if (size > 1) {
          unindent(2);
        }
      }
    } else {
      visitCommaSeparatedNodes(node.variables);
    }
  }

  visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    visit(node.variables);
    token(node.semicolon);
  }

  visitWhileStatement(WhileStatement node) {
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    allowContinuedLines(() {
      visit(node.condition);
      token(node.rightParenthesis);
    });
    if (node.body is! EmptyStatement) {
      space();
    }
    visit(node.body);
  }

  visitWithClause(WithClause node) {
    token(node.withKeyword);
    space();
    visitCommaSeparatedNodes(node.mixinTypes);
  }

  @override
  visitYieldStatement(YieldStatement node) {
    token(node.yieldKeyword);
    token(node.star);
    space();
    visit(node.expression);
    token(node.semicolon);
  }

  /// Safely visit the given [node].
  visit(AstNode node) {
    if (node != null) {
      node.accept(this);
    }
  }

  /// Visit member metadata
  visitMemberMetadata(NodeList<Annotation> metadata) {
    visitNodes(metadata,
      separatedBy: () {
        space();
        preserveLeadingNewlines();
      },
      followedBy: space);
    if (metadata != null && metadata.length > 0) {
      preserveLeadingNewlines();
    }
  }

  /// Visit member metadata
  visitDirectiveMetadata(NodeList<Annotation> metadata) {
    visitNodes(metadata, separatedBy: newlines, followedBy: newlines);
  }

  /// Visit the given function [body], printing the [prefix] before if given
  /// body is not empty.
  visitPrefixedBody(prefix(), FunctionBody body) {
    if (body is! EmptyFunctionBody) {
      prefix();
    }
    visit(body);
  }

  /// Visit a list of [nodes] if not null, optionally separated and/or preceded
  /// and followed by the given functions.
  visitNodes(NodeList<AstNode> nodes, {precededBy(): null,
      separatedBy() : null, followedBy(): null}) {
    if (nodes != null) {
      var size = nodes.length;
      if (size > 0) {
        if (precededBy != null) {
          precededBy();
        }
        for (var i = 0; i < size; i++) {
          if (i > 0 && separatedBy != null) {
            separatedBy();
          }
          nodes[i].accept(this);
        }
        if (followedBy != null) {
          followedBy();
        }
      }
    }
  }

  /// Visit a comma-separated list of [nodes] if not null.
  visitCommaSeparatedNodes(NodeList<AstNode> nodes, {followedBy(): null}) {
    //TODO(pquitslund): handle this more neatly
    if (followedBy == null) {
      followedBy = space;
    }
    if (nodes != null) {
      var size = nodes.length;
      if (size > 0) {
        var node;
        for (var i = 0; i < size; i++) {
          node = nodes[i];
          if (i > 0) {
            var comma = node.beginToken.previous;
            token(comma);
            followedBy();
          }
          node.accept(this);
        }
      }
    }
  }


  /// Visit a [node], and if not null, optionally preceded or followed by the
  /// specified functions.
  visitNode(AstNode node, {precededBy(): null, followedBy(): null}) {
    if (node != null) {
      if (precededBy != null) {
        precededBy();
      }
      node.accept(this);
      if (followedBy != null) {
        followedBy();
      }
    }
  }

  /// Allow [code] to be continued across lines.
  allowContinuedLines(code()) {
    //TODO(pquitslund): add before
    code();
    //TODO(pquitslund): add after
  }

  /// Emit the given [modifier] if it's non null, followed by non-breaking
  /// whitespace.
  modifier(Token modifier) {
    token(modifier, followedBy: space);
  }

  /// Indicate that at least one newline should be emitted and possibly more
  /// if the source has them.
  newlines() {
    needsNewline = true;
  }

  /// Optionally emit a trailing comma.
  optionalTrailingComma(Token rightBracket) {
    if (rightBracket.previous.lexeme == ',') {
      token(rightBracket.previous);
    }
  }

  /// Indicate that user introduced newlines should be emitted before the next
  /// token.
  preserveLeadingNewlines() {
    preserveNewlines = true;
  }

  token(Token token, {precededBy(), followedBy(), printToken(Token tok)}) {
    if (token == null) return;

    emitPrecedingCommentsAndNewlines(token);

    if (precededBy != null) precededBy();

    checkForSelectionUpdate(token);
    if (printToken == null) {
      append(token.lexeme);
    } else {
      printToken(token);
    }

    if (followedBy != null) followedBy();

    previousToken = token;
  }

  emitSpaces() {
    if (leadingSpaces > 0 || emitEmptySpaces) {
      if (allowLineLeadingSpaces || !writer.currentLine.isWhitespace()) {
        writer.spaces(leadingSpaces, breakWeight: currentBreakWeight);
      }
      leadingSpaces = 0;
      allowLineLeadingSpaces = false;
      emitEmptySpaces = false;
      currentBreakWeight = DEFAULT_SPACE_WEIGHT;
    }
  }

  checkForSelectionUpdate(Token token) {
    // Cache the first token on or AFTER the selection offset
    if (preSelection != null && selection == null) {
      // Check for overshots
      var overshot = token.offset - preSelection.offset;
      if (overshot >= 0) {
        //TODO(pquitslund): update length (may need truncating)
        selection = new Selection(
            writer.toString().length + leadingSpaces - overshot,
            preSelection.length);
      }
    }
  }

  /// Emit a breakable 'non' (zero-length) space
  breakableNonSpace() {
    space(n: 0);
    emitEmptySpaces = true;
  }

  /// Emit level spaces, even if empty (works as a break point).
  levelSpace(int weight, [int n = 1]) {
    space(n: n, breakWeight: weight);
    emitEmptySpaces = true;
  }

  /// Emit a non-breakable space.
  nonBreakingSpace() {
    space(breakWeight: UNBREAKABLE_SPACE_WEIGHT);
  }

  /// Emit a space. If [allowLineLeading] is specified, spaces
  /// will be preserved at the start of a line (in addition to the
  /// indent-level), otherwise line-leading spaces will be ignored.
  space({n: 1, allowLineLeading: false, breakWeight: DEFAULT_SPACE_WEIGHT}) {
    // TODO(pquitslund): replace with a proper space token.
    leadingSpaces += n;
    allowLineLeadingSpaces = allowLineLeading;
    currentBreakWeight = breakWeight;
  }

  /// Append the given [string] to the source writer if it's non-null.
  append(String string) {
    if (string == null || string.isEmpty) return;

    emitSpaces();
    writer.write(string);
  }

  /// Indent.
  indent([n = 1]) {
    while (n-- > 0) {
      writer.indent();
    }
  }

  /// Unindent
  unindent([n = 1]) {
    while (n-- > 0) {
      writer.unindent();
    }
  }

  /// Emit any detected comments and newlines or a minimum as specified
  /// by [min].
  void emitPrecedingCommentsAndNewlines(Token token) {
    var comment = token.precedingComments;
    var currentToken = comment != null ? comment : token;

    // Handle EOLs before newlines.
    if (isAtEOL(comment)) {
      emitComment(comment, previousToken);
      comment = comment.next;
      currentToken = comment != null ? comment : token;

      // Ensure EOL comments force a linebreak.
      needsNewline = true;
    }

    var lines = 0;
    if (needsNewline || preserveNewlines) {
      if (needsNewline) lines = 1;

      lines = max(lines, countNewlinesBetween(previousToken, currentToken));
      preserveNewlines = false;

      emitNewlines(lines);
    }

    previousToken = currentToken.previous != null ? currentToken.previous :
        token.previous;

    while (comment != null) {
      emitComment(comment, previousToken);

      var nextToken = comment.next != null ? comment.next : token;
      var newlines = calculateNewlinesBetweenComments(comment, nextToken);
      if (newlines > 0) {
        emitNewlines(newlines);
        lines += newlines;
      } else {
        // Collapse spaces after a comment to a single space.
        var spaces = countSpacesBetween(comment, nextToken);
        if (spaces > 0) space();
      }

      previousToken = comment;
      comment = comment.next;
    }

    if (lines > 0) needsNewline = false;

    previousToken = token;
  }

  /// Writes [count] newlines to the output.
  void emitNewlines(int count) {
    writer.newlines(count);
  }

  /// Writes a newline to the output if haven't just done so.
  void ensureTrailingNewline() {
    if (writer.lastToken is! NewlineToken) {
      writer.newline();
    }
  }

  /// Test if this EOL [comment] is at the beginning of a line.
  bool isAtBOL(Token comment) =>
      lineInfo.getLocation(comment.offset).columnNumber == 1;

  /// Test if this [comment] is at the end of a line.
  bool isAtEOL(Token comment) =>
      comment != null && comment.toString().trim().startsWith(twoSlashes) &&
      sameLine(comment, previousToken);

  /// Emit this [comment], inserting leading whitespace if appropriate.
  emitComment(Token comment, Token previousToken) {
    if (!writer.currentLine.isWhitespace() && previousToken != null) {
      var spaces = countSpacesBetween(previousToken, comment);
      // Preserve one space but no more.
      if (spaces > 0 && leadingSpaces == 0) space();
    }

    // Don't indent commented-out lines.
    if (isAtBOL(comment)) {
      writer.currentLine.clear();
    }

    append(comment.toString().trim());
  }

  /// Count spaces between [last] and [current].
  ///
  /// Tokens on different lines return 0.
  int countSpacesBetween(Token last, Token current) => isEOF(last) ||
      countNewlinesBetween(last, current) > 0 ? 0 : current.offset - last.end;

  /// Count the blank lines between [lastNode] and [currentNode].
  int countBlankLinesBetween(AstNode lastNode, AstNode currentNode) =>
      countNewlinesBetween(lastNode.endToken, currentNode.beginToken);

  /// Count newlines preceeding this [node].
  int countPrecedingNewlines(AstNode node) =>
      countNewlinesBetween(node.beginToken.previous, node.beginToken);

  /// Count newlines succeeding this [node].
  int countSucceedingNewlines(AstNode node) => node == null ? 0 :
      countNewlinesBetween(node.endToken, node.endToken.next);

  /// Count the blanks between these two tokens.
  int countNewlinesBetween(Token last, Token current) {
    if (last == null || current == null) return 0;

    return linesBetween(last.end - 1, current.offset);
  }

  /// Calculate the newlines that should separate these comments.
  int calculateNewlinesBetweenComments(Token last, Token current) {
    // Insist on a newline after doc comments or single line comments
    // (NOTE that EOL comments have already been processed).
    if (isOldSingleLineDocComment(last) || isSingleLineComment(last)) {
      return max(1, countNewlinesBetween(last, current));
    } else {
      return countNewlinesBetween(last, current);
    }
  }

  /// Single line multi-line comments (e.g., '/** like this */').
  bool isOldSingleLineDocComment(Token comment) =>
      comment.lexeme.startsWith(r'/**') && singleLine(comment);

  /// Test if this [token] spans just one line.
  bool singleLine(Token token) => linesBetween(token.offset, token.end) < 1;

  /// Test if token [first] is on the same line as [second].
  bool sameLine(Token first, Token second) =>
      countNewlinesBetween(first, second) == 0;

  /// Test if this is a multi-line [comment] (e.g., '/* ...' or '/** ...')
  bool isMultiLineComment(Token comment) =>
      comment.type == TokenType.MULTI_LINE_COMMENT;

  /// Test if this is a single-line [comment] (e.g., '// ...')
  bool isSingleLineComment(Token comment) =>
      comment.type == TokenType.SINGLE_LINE_COMMENT;

  /// Test if this [comment] is a block comment (e.g., '/* like this */')..
  bool isBlock(Token comment) =>
      isMultiLineComment(comment) && singleLine(comment);

  /// Count the lines between two offsets.
  int linesBetween(int lastOffset, int currentOffset) {
    var lastLine =
        lineInfo.getLocation(lastOffset).lineNumber;
    var currentLine =
        lineInfo.getLocation(currentOffset).lineNumber;
    return currentLine - lastLine;
  }

  /// Test if this token is an EOF token.
  bool isEOF(Token token) => token != null && token.type == TokenType.EOF;

  String toString() => writer.toString();

  @override
  visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    // TODO: implement visitEnumConstantDeclaration
  }

  @override
  visitEnumDeclaration(EnumDeclaration node) {
    // TODO: implement visitEnumDeclaration
  }
}
