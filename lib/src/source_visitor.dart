// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'dart:math';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import '../dart_style.dart';
import 'line.dart';
import 'source_writer.dart';
import 'splitter.dart';

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

  /// True if a space should be emitted before the next non-space text.
  ///
  /// This is added lazily so that we don't emit trailing whitespace.
  bool _pendingSpace = false;

  /// Original pre-format selection information (may be null).
  final Selection preSelection;

  /// The source being formatted (used in interpolation handling)
  final String source;

  /// Post format selection information.
  Selection selection;

  /// Keep track of which collection literals are currently being written
  ///
  /// A collection can either be single line:
  ///
  ///    [all, on, one, line];
  ///
  /// or multi-line:
  ///
  ///    [
  ///      one,
  ///      item,
  ///      per,
  ///      line
  ///    ]
  ///
  /// Collections can also contain function expressions, which have blocks which
  /// in turn force a newline in the middle of the collection. When that
  /// happens, we need to force all surrounding collections to be multi-line.
  /// This tracks them so we can do that.
  final _collections = <CollectionSplitRule>[];

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(FormatterOptions options, this.lineInfo, this.source,
    this.preSelection)
      : writer = new SourceWriter(indent: options.initialIndentationLevel,
                                lineSeparator: options.lineSeparator,
                                pageWidth: options.pageWidth);

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
      // Allow splitting after "(".
      zeroSplit();

      visitCommaSeparatedNodes(node.arguments, followedBy: split);
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
    split();
    visit(node.rightHandSide);
  }

  @override
  visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  visitBinaryExpression(BinaryExpression node) {
    var operands = [];

    // Flatten out a tree/chain of the same operator type and give them all the
    // same space weight. If we break on this operator, we will break all of
    // them.
    addOperands(Expression e) {
      if (e is BinaryExpression && e.operator.type == node.operator.type) {
        addOperands(e.leftOperand);
        addOperands(e.rightOperand);
      } else {
        operands.add(e);
      }
    }

    addOperands(node.leftOperand);
    addOperands(node.rightOperand);

    for (var i = 0; i < operands.length; i++) {
      if (i != 0) {
        space();
        token(node.operator);
        space();
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
    token(node.keyword, followedBy: space);

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
    visit(node.typeParameters);
    visitNode(node.extendsClause, precededBy: space);
    visitNode(node.withClause, precededBy: space);
    visitNode(node.implementsClause, precededBy: space);
    visitNode(node.nativeClause, precededBy: space);
    space();
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
    if (!writer.currentLine.isEmpty) emitNewlines(1);
  }

  visitConditionalExpression(ConditionalExpression node) {
    visit(node.condition);
    space();
    token(node.question);
    space();
    visit(node.thenExpression);
    space();
    token(node.colon);
    space();
    visit(node.elseExpression);
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
      space();
    }

    indent(2);
    token(node.separator /* : */);
    space();

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);
        newlines();
      }

      // Indent subsequent fields one more so they line up with the first
      // field following the ":":
      //
      // Foo()
      //   : first,
      //     second;
      if (i == 1) indent();

      node.initializers[i].accept(this);
    }

    // If there were multiple fields, discard their extra indentation.
    if (node.initializers.length > 1) unindent();

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
    visit(node.condition);
    token(node.rightParenthesis);
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
    visitNodes(node.combinators, precededBy: space, separatedBy: space);
    token(node.semicolon);
  }

  visitExpressionFunctionBody(ExpressionFunctionBody node) {
    // The "async" or "sync" keyword.
    token(node.keyword, followedBy: space);

    token(node.functionDefinition);

    space();
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
    token(node.leftParenthesis);

    if (node.parameters.isNotEmpty) {
      var groupEnd;

      // TODO(rnystrom): Test.
      // Allow splitting after the "(".
      zeroSplit();

      for (var i = 0; i < node.parameters.length; i++) {
        var parameter = node.parameters[i];
        if (i > 0) {
          append(',');
          split();
        }

        if (groupEnd == null && parameter is DefaultFormalParameter) {
          if (parameter.kind == ParameterKind.NAMED) {
            groupEnd = '}';
            append('{');
          } else {
            groupEnd = ']';
            append('[');
          }
        }

        visit(parameter);
      }

      if (groupEnd != null) append(groupEnd);
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
    space();
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
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
    space();
    visit(node.uri);
    token(node.deferredToken, precededBy: space);
    token(node.asToken, precededBy: space, followedBy: space);
    visit(node.prefix);
    visitNodes(node.combinators, precededBy: space, separatedBy: space);
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
    space();
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
    modifier(node.constKeyword);
    visit(node.typeArguments);
    token(node.leftBracket);

    // TODO(rnystrom): Test this by ensuring never splits on [].
    if (node.elements.isEmpty) {
      token(node.rightBracket);
      return;
    }

    var rule = new CollectionSplitRule();
    _collections.add(rule);

    // Track indentation in case the list contains a function expression with
    // a block body that splits to a new line.
    indent();

    var chunk = new SplitChunk.forRule(rule, writer.indent, param: rule.param);
    split(chunk);

    visitCommaSeparatedNodes(node.elements,  followedBy: () {
      split(new SplitChunk.forRule(rule, writer.indent, param: rule.param,
          text: " "));
    });

    optionalTrailingComma(node.rightBracket);

    unindent();

    chunk = new SplitChunk.forRule(rule, writer.indent, param: rule.param);
    split(chunk);

    _collections.removeLast();

    token(node.rightBracket);
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
    visitPrefixedBody(space, node.body);
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
      space();
      expression.accept(this);
      token(node.semicolon);
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
    visitNode(node.type, followedBy: space);
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
    if (node.initializer == null) return;

    space();
    token(node.equals);
    split();
    visit(node.initializer);
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    visitMemberMetadata(node.metadata);
    modifier(node.keyword);
    visitNode(node.type, followedBy: space);

    if (node.variables.length == 1) {
      visit(node.variables.single);
      return;
    }

    // If there are multiple declarations and any of them have initializers,
    // put them all on their own lines.
    if (node.variables.any((variable) => variable.initializer != null)) {
      visit(node.variables.first);

      // Indent variables after the first one to line up past "var".
      indent(2);

      for (var variable in node.variables.skip(1)) {
        token(variable.beginToken.previous); // Comma.
        newlines();

        visit(variable);
      }

      unindent(2);
      return;
    }

    // TODO(bob): Doc.
    var param = new SplitParam();

    visitCommaSeparatedNodes(node.variables, followedBy: () {
      split(new SplitChunk(writer.indent + 2, param: param, text: " "));
    });
  }

  visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    visit(node.variables);
    token(node.semicolon);
  }

  visitWhileStatement(WhileStatement node) {
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
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
    // TODO(rnystrom): As I move stuff over to the new split architecture, more
    // calls to this are passing in a followedBy to handle splitting. If they
    // eventually all do that, move that into here.
    if (nodes == null || nodes.isEmpty) return;

    if (followedBy == null) followedBy = space;

    visit(nodes.first);

    for (var node in nodes.skip(1)) {
      token(node.beginToken.previous); // Comma.
      followedBy();
      visit(node);
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

  checkForSelectionUpdate(Token token) {
    // Cache the first token on or AFTER the selection offset.
    if (preSelection != null && selection == null) {
      // Check for overshots.
      var overshot = token.offset - preSelection.offset;
      if (overshot >= 0) {
        // TODO(pquitslund): update length (may need truncating).
        var space = _pendingSpace ? 1 : 0;
        selection = new Selection(
            writer.toString().length + space - overshot,
            preSelection.length);
      }
    }
  }

  /// Emit a non-breaking space.
  ///
  /// Since these, by definition, cannot affect line breaking, they are treated
  /// like regular non-space text.
  void space() {
    assert(!_pendingSpace); // Should not already have a pending space.
    _pendingSpace = true;
  }

  /// Emits a zero-width separator that can be used to break a line.
  void zeroSpace() {
    // TODO(rnystrom): Does nothing now that line wrapping is (temporarily)
    // removed. Preserved so I can remember where these should go.
  }

  /// Append the given [string] to the source writer if it's non-null.
  void append(String string) {
    if (string == null || string.isEmpty) return;

    _emitPendingSpace();
    writer.write(string);
  }

  /// Outputs the next pending space token, if any.
  void _emitPendingSpace() {
    if (!_pendingSpace) return;

    if (!writer.currentLine.isEmpty) {
      writer.currentLine.write(" ");
    }

    _pendingSpace = false;
  }

  /// Outputs a [SplitChunk] bound to [splitter] with the given properties.
  void split([SplitChunk chunk]) {
    if (chunk == null) chunk = new SplitChunk(writer.indent + 2, text: " ");
    writer.currentLine.split(chunk);
  }

  /// Outputs a [SplitChunk] that is the empty string when unsplit and indents
  /// two levels (i.e. a wrapped statement) when split.
  void zeroSplit() {
    writer.currentLine.split(new SplitChunk(writer.indent + 2));
  }

  /// Increase indentation by [n] levels.
  indent([n = 1]) {
    writer.indent += n;
  }

  /// Decrease indentation by [n] levels.
  unindent([n = 1]) {
    writer.indent -= n;
  }

  /// Emit any detected comments and newlines or a minimum as specified
  /// by [min].
  void emitPrecedingCommentsAndNewlines(Token token) {
    var comment = token.precedingComments;
    var currentToken = comment != null ? comment : token;

    // Handle EOLs before newlines.
    if (_isAtEOL(comment)) {
      _emitComment(comment, previousToken);
      comment = comment.next;
      currentToken = comment != null ? comment : token;

      // Ensure EOL comments force a linebreak.
      needsNewline = true;
    }

    var lines = 0;
    if (needsNewline || preserveNewlines) {
      if (needsNewline) lines = 1;

      lines = max(lines, _countNewlinesBetween(previousToken, currentToken));
      preserveNewlines = false;

      emitNewlines(lines);
    }

    previousToken = currentToken.previous != null ? currentToken.previous :
        token.previous;

    while (comment != null) {
      _emitComment(comment, previousToken);

      var nextToken = comment.next != null ? comment.next : token;
      var newlines = _calculateNewlinesBetweenComments(comment, nextToken);
      if (newlines > 0) {
        emitNewlines(newlines);
        lines += newlines;
      } else {
        // Collapse spaces after a comment to a single space.
        var spaces = _countSpacesBetween(comment, nextToken);
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
    // If we are in the middle of collections that might need splitting, we
    // know they are definitely going to be multi-line now.
    for (var collection in _collections) {
      collection.param.force();
    }

    // TODO(rnystrom): Count should never be > 2 here. We don't want to allow
    // extra newlines. Ensure this.
    for (var i = 0; i < count; i++) {
      writer.newline();
    }
  }

  /// Test if this [comment] is at the end of a line.
  bool _isAtEOL(Token comment) =>
      comment != null && comment.toString().trim().startsWith(twoSlashes) &&
      _sameLine(comment, previousToken);

  /// Emit this [comment], inserting leading whitespace if appropriate.
  void _emitComment(Token comment, Token previousToken) {
    if (!writer.currentLine.isEmpty && previousToken != null) {
      var spaces = _countSpacesBetween(previousToken, comment);
      // Preserve one space but no more.
      if (spaces > 0 && !_pendingSpace) space();
    }

    // If the line comment is at the beginning of a line, meaning the user has
    // commented out the entire line, then don't indent it.
    // TODO(rnystrom): Is this the behavior we want?
    if (lineInfo.getLocation(comment.offset).columnNumber == 1) {
      writer.currentLine.clearIndentation();
    }

    append(comment.toString().trim());
  }

  /// Count spaces between [last] and [current].
  ///
  /// Tokens on different lines return 0.
  int _countSpacesBetween(Token last, Token current) {
    if (last == null || last.type == TokenType.EOF) return 0;

    if (_countNewlinesBetween(last, current) > 0) return 0;

    return current.offset - last.end;
  }

  /// Count the blanks between these two tokens.
  int _countNewlinesBetween(Token last, Token current) {
    if (last == null || current == null) return 0;

    return _linesBetween(last.end - 1, current.offset);
  }

  /// Calculate the newlines that should separate these comments.
  int _calculateNewlinesBetweenComments(Token last, Token current) {
    // Insist on a newline after doc comments or single line comments
    // (NOTE that EOL comments have already been processed).
    if (_isOldSingleLineDocComment(last) || _isSingleLineComment(last)) {
      return max(1, _countNewlinesBetween(last, current));
    } else {
      return _countNewlinesBetween(last, current);
    }
  }

  /// Single line multi-line comments (e.g., '/** like this */').
  bool _isOldSingleLineDocComment(Token comment) =>
      comment.lexeme.startsWith(r'/**') && _singleLine(comment);

  /// Test if this [token] spans just one line.
  bool _singleLine(Token token) => _linesBetween(token.offset, token.end) < 1;

  /// Test if token [first] is on the same line as [second].
  bool _sameLine(Token first, Token second) =>
      _countNewlinesBetween(first, second) == 0;

  /// Test if this is a multi-line [comment] (e.g., '/* ...' or '/** ...')
  bool _isMultiLineComment(Token comment) =>
      comment.type == TokenType.MULTI_LINE_COMMENT;

  /// Test if this is a single-line [comment] (e.g., '// ...')
  bool _isSingleLineComment(Token comment) =>
      comment.type == TokenType.SINGLE_LINE_COMMENT;

  /// Count the lines between two offsets.
  int _linesBetween(int lastOffset, int currentOffset) {
    var lastLine = lineInfo.getLocation(lastOffset).lineNumber;
    var currentLine = lineInfo.getLocation(currentOffset).lineNumber;
    return currentLine - lastLine;
  }

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
