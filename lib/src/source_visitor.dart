// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import '../dart_style.dart';
import 'line.dart';
import 'source_writer.dart';

/// Used for matching EOL comments
final twoSlashes = new RegExp(r'//[^/]');

// TODO(rnystrom): Move elsewhere?
/// The kind of pending whitespace that has been "written", but not actually
/// physically output yet.
///
/// We defer actually writing whitespace until a non-whitespace token is
/// encountered to avoid trailing whitespace.
class Whitespace {
  /// A single non-breaking space.
  static const SPACE = const Whitespace._("SPACE");

  /// A single newline.
  static const NEWLINE = const Whitespace._("NEWLINE");

  /// Two newlines, a single blank line of separation.
  static const TWO_NEWLINES = const Whitespace._("TWO_NEWLINES");

  /// A space or newline should be output based on whether the current token is
  /// on the same line as the previous one or not.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const SPACE_OR_NEWLINE = const Whitespace._("SPACE_OR_NEWLINE");

  /// One or two newlines should be output based on how many newlines are
  /// present between the next token and the previous one.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const ONE_OR_TWO_NEWLINES = const Whitespace._("ONE_OR_TWO_NEWLINES");

  final String name;

  const Whitespace._(this.name);

  String toString() => name;
}

/// An AST visitor that drives formatting heuristics.
class SourceVisitor implements AstVisitor {
  /// The writer to which the source is to be written.
  final SourceWriter writer;

  /// Cached line info for calculating blank lines.
  LineInfo lineInfo;

  /// The whitespace that should be written before the next non-whitespace token
  /// or `null` if no whitespace is pending.
  Whitespace _pending;

  /// The source being formatted (used in interpolation handling)
  final String source;

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(FormatterOptions options, this.lineInfo, this.source)
      : writer = new SourceWriter(indent: options.initialIndentationLevel,
                                lineSeparator: options.lineSeparator,
                                pageWidth: options.pageWidth);

  visitAdjacentStrings(AdjacentStrings node) {
    visitNodes(node.strings,
        between: () => split(cost: SplitCost.ADJACENT_STRINGS));
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
      // See if we kept all of the arguments on the same line.
      writer.startSpan();

      // Allow splitting after "(".
      zeroSplit(SplitCost.BEFORE_ARGUMENT);

      // Prefer splitting later arguments over earlier ones.
      var cost = SplitCost.BEFORE_ARGUMENT + node.arguments.length + 1;
      visitCommaSeparatedNodes(node.arguments,
          after: () => split(cost: cost--));

      writer.endSpan(SplitCost.SPLIT_ARGUMENTS);
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
    split(cost: SplitCost.ASSIGNMENT);
    visit(node.rightHandSide);
  }

  visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  visitBinaryExpression(BinaryExpression node) {
    var operands = [];

    // Flatten out a tree/chain of the same operator type. If we split on this
    // operator, we will break all of them.
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

    // TODO(rnystrom: Use different costs for different operator precedences.
    writer.startMultisplit(SplitCost.BINARY_OPERATOR);

    for (var i = 0; i < operands.length; i++) {
      if (i != 0) {
        space();
        token(node.operator);
        writer.multisplit(indent: 2, text: " ");
      }
      visit(operands[i]);
    }

    writer.endMultisplit();
  }

  visitBlock(Block node) {
    token(node.leftBracket);
    indent();
    if (!node.statements.isEmpty) {
      newline();
      visitNodes(node.statements, between: oneOrTwoNewlines);
      newline();
    }
    token(node.rightBracket, before: unindent);
  }

  visitBlockFunctionBody(BlockFunctionBody node) {
    // The "async" or "sync" keyword.
    token(node.keyword, after: space);

    visit(node.block);
  }

  visitBooleanLiteral(BooleanLiteral node) {
    token(node.literal);
  }

  visitBreakStatement(BreakStatement node) {
    token(node.keyword);
    visitNode(node.label, before: space);
    token(node.semicolon);
  }

  visitCascadeExpression(CascadeExpression node) {
    visit(node.target);
    indent(2);
    // Single cascades do not force a linebreak (dartbug.com/16384)
    if (node.cascadeSections.length > 1) {
      newline();
    }
    visitNodes(node.cascadeSections, between: newline);
    unindent(2);
  }

  visitCatchClause(CatchClause node) {
    token(node.onKeyword, after: space);
    visit(node.exceptionType);

    if (node.catchKeyword != null) {
      if (node.exceptionType != null) {
        space();
      }
      token(node.catchKeyword);
      space();
      token(node.leftParenthesis);
      visit(node.exceptionParameter);
      token(node.comma, after: space);
      visit(node.stackTraceParameter);
      token(node.rightParenthesis);
      space();
    } else {
      space();
    }
    visit(node.body);
  }

  visitClassDeclaration(ClassDeclaration node) {
    visitDeclarationMetadata(node.metadata);
    modifier(node.abstractKeyword);
    token(node.classKeyword);
    space();
    visit(node.name);
    visit(node.typeParameters);
    visitNode(node.extendsClause);
    visitNode(node.withClause);
    visitNode(node.implementsClause);
    visitNode(node.nativeClause, before: space);
    space();
    token(node.leftBracket);
    indent();
    if (!node.members.isEmpty) {
      visitNodes(node.members, before: newline,
          between: oneOrTwoNewlines);
      newline();
    }
    token(node.rightBracket, before: unindent);
  }

  visitClassTypeAlias(ClassTypeAlias node) {
    visitDeclarationMetadata(node.metadata);
    modifier(node.abstractKeyword);
    token(node.keyword);
    space();
    visit(node.name);
    visit(node.typeParameters);
    space();
    token(node.equals);
    space();
    visit(node.superclass);
    visitNode(node.withClause);
    visitNode(node.implementsClause);
    token(node.semicolon);
  }

  visitComment(Comment node) => null;

  visitCommentReference(CommentReference node) => null;

  visitCompilationUnit(CompilationUnit node) {
    var scriptTag = node.scriptTag;
    var directives = node.directives;
    visit(scriptTag);

    visitNodes(directives, between: oneOrTwoNewlines, after: twoNewlines);

    visitNodes(node.declarations, between: oneOrTwoNewlines);

    // Output trailing comments.
    token(node.endToken); // EOF.

    // Be a good citizen, end with a newline.
    if (!writer.isCurrentLineEmpty) writer.newline();
  }

  visitConditionalExpression(ConditionalExpression node) {
    visit(node.condition);
    space();
    token(node.question);
    split(cost: SplitCost.AFTER_CONDITION);
    visit(node.thenExpression);
    space();
    token(node.colon);
    split(cost: SplitCost.AFTER_COLON);
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

    visitBody(node.body);
  }

  visitConstructorInitializers(ConstructorDeclaration node) {
    if (node.initializers.length > 1) {
      newline();
    } else {
      split();
    }

    indent(2);
    token(node.separator /* : */);
    space();

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);
        newline();
      }

      // Indent subsequent fields one more so they line up with the first
      // field following the ":":
      //
      // Foo()
      //     : first,
      //       second;
      if (i == 1) indent();

      node.initializers[i].accept(this);
    }

    // If there were multiple fields, discard their extra indentation.
    if (node.initializers.length > 1) unindent();

    unindent(2);
  }

  visitConstructorRedirects(ConstructorDeclaration node) {
    token(node.separator /* = */, before: space, after: space);
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
    visitNode(node.label, before: space);
    token(node.semicolon);
  }

  visitDeclaredIdentifier(DeclaredIdentifier node) {
    modifier(node.keyword);
    visitNode(node.type, after: space);
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
      visitNode(node.defaultValue, before: space);
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
    visitDeclarationMetadata(node.metadata);
    token(node.keyword);
    space();
    visit(node.uri);
    visitNodes(node.combinators, before: space, between: space);
    token(node.semicolon);
  }

  visitExpressionFunctionBody(ExpressionFunctionBody node) {
    // The "async" or "sync" keyword.
    token(node.keyword, after: space);

    token(node.functionDefinition); // "=>".
    split(cost: SplitCost.ARROW);
    visit(node.expression);
    token(node.semicolon);
  }

  visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    token(node.semicolon);
  }

  visitExtendsClause(ExtendsClause node) {
    split(cost: SplitCost.BEFORE_EXTENDS);
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
    token(node.keyword, after: space);
    visitNode(node.type, after: space);
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

  visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    throw new UnimplementedError("Enum formatting is not implemented yet.");
  }

  visitEnumDeclaration(EnumDeclaration node) {
    throw new UnimplementedError("Enum formatting is not implemented yet.");
  }

  visitFormalParameterList(FormalParameterList node) {
    token(node.leftParenthesis);

    if (node.parameters.isNotEmpty) {
      var groupEnd;

      // Allow splitting after the "(" but not for lambdas.
      if (node.parent is! FunctionExpression) {
        zeroSplit(SplitCost.BEFORE_ARGUMENT);
      }

      for (var i = 0; i < node.parameters.length; i++) {
        var parameter = node.parameters[i];
        if (i > 0) {
          append(',');
          // Prefer splitting later parameters over earlier ones.
          split(cost: SplitCost.BEFORE_ARGUMENT +
              node.parameters.length + 1 - i);
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
    visitMemberMetadata(node.metadata);
    modifier(node.externalKeyword);
    visitNode(node.returnType, after: space);
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
    visitDeclarationMetadata(node.metadata);
    token(node.keyword);
    space();
    visitNode(node.returnType, after: space);
    visit(node.name);
    visit(node.typeParameters);
    visit(node.parameters);
    token(node.semicolon);
  }

  visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    visitNode(node.returnType, after: space);
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
    split(cost: SplitCost.BEFORE_IMPLEMENTS);
    token(node.keyword);
    space();
    visitCommaSeparatedNodes(node.interfaces);
  }

  visitImportDirective(ImportDirective node) {
    visitDeclarationMetadata(node.metadata);
    token(node.keyword);
    space();
    visit(node.uri);
    token(node.deferredToken, before: space);
    token(node.asToken, before: split, after: space);
    visit(node.prefix);
    visitNodes(node.combinators, before: space, between: space);
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
    visitNodes(node.labels, between: space, after: space);
    visit(node.statement);
  }

  visitLibraryDirective(LibraryDirective node) {
    visitDeclarationMetadata(node.metadata);
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

    writer.startMultisplit();

    // Track indentation in case the list contains a function expression with
    // a block body that splits to a new line.
    indent();

    writer.multisplit();

    visitCommaSeparatedNodes(node.elements, after: () {
      writer.multisplit(text: " ");
    });

    optionalTrailingComma(node.rightBracket);

    unindent();

    writer.multisplit();
    writer.endMultisplit();

    token(node.rightBracket);
  }

  visitMapLiteral(MapLiteral node) {
    modifier(node.constKeyword);
    visitNode(node.typeArguments);
    token(node.leftBracket);

    if (node.entries.isEmpty) {
      token(node.rightBracket);
      return;
    }

    writer.startMultisplit();

    // Track indentation in case the map contains a function expression with
    // a block body that splits to a new line.
    indent();

    writer.multisplit();

    visitCommaSeparatedNodes(node.entries, after: () {
      writer.multisplit(text: " ");
    });

    optionalTrailingComma(node.rightBracket);

    unindent();

    writer.multisplit();
    writer.endMultisplit();

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
    visitNode(node.returnType, after: space);
    modifier(node.propertyKeyword);
    modifier(node.operatorKeyword);
    visit(node.name);
    if (!node.isGetter) {
      visit(node.parameters);
    }

    visitBody(node.body);
  }

  visitMethodInvocation(MethodInvocation node) {
    // Make sure it has an explicit receiver.
    if (node.period != null) {
      visit(node.target);
      zeroSplit(SplitCost.BEFORE_PERIOD);
      token(node.period);
    }

    visit(node.methodName);
    visit(node.argumentList);
  }

  visitNamedExpression(NamedExpression node) {
    visit(node.name);
    visitNode(node.expression, before: space);
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
    visitParameterMetadata(node.metadata);
    modifier(node.keyword);
    visitNode(node.type, after: space);
    visit(node.identifier);
  }

  visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  visitSimpleStringLiteral(SimpleStringLiteral node) {
    token(node.literal);
  }

  visitStringInterpolation(StringInterpolation node) {
    // Ensure that interpolated strings don't get broken up by manually
    // outputting them as an unformatted substring of the source.
    _writePrecedingCommentsAndNewlines(node.beginToken);
    append(source.substring(node.beginToken.offset, node.endToken.end));
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
    visitNodes(node.labels, between: space, after: space);
    token(node.keyword);
    space();
    visit(node.expression);
    token(node.colon);
    newline();
    indent();
    visitNodes(node.statements, between: oneOrTwoNewlines);
    unindent();
  }

  visitSwitchDefault(SwitchDefault node) {
    visitNodes(node.labels, between: space, after: space);
    token(node.keyword);
    token(node.colon);
    newline();
    indent();
    visitNodes(node.statements, between: oneOrTwoNewlines);
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
    newline();
    visitNodes(node.members, between: oneOrTwoNewlines, after: newline);
    token(node.rightBracket, before: unindent);

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
    visitNodes(node.catchClauses, before: space, between: space);
    token(node.finallyKeyword, before: space, after: space);
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
    visitParameterMetadata(node.metadata);
    visit(node.name);
    token(node.keyword /* extends */, before: space, after: space);
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
    split(cost: SplitCost.ASSIGNMENT);
    visit(node.initializer);
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    visitDeclarationMetadata(node.metadata);
    modifier(node.keyword);
    visitNode(node.type, after: space);

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
        newline();

        visit(variable);
      }

      unindent(2);
      return;
    }

    // Use a single param for all of the splits. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    var param = new SplitParam(SplitCost.DECLARATION);

    visitCommaSeparatedNodes(node.variables, after: () {
      split(chunk: new SplitChunk(writer.indent + 2, param, " "));
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
    split(cost: SplitCost.BEFORE_WITH);
    token(node.withKeyword);
    space();
    visitCommaSeparatedNodes(node.mixinTypes);
  }

  visitYieldStatement(YieldStatement node) {
    token(node.yieldKeyword);
    token(node.star);
    space();
    visit(node.expression);
    token(node.semicolon);
  }

  /// Safely visit the given [node].
  void visit(AstNode node) {
    if (node != null) {
      node.accept(this);
    }
  }

  /// Visit metadata annotations on directives and declarations.
  ///
  /// These always force the annotations to be on the previous line.
  void visitDeclarationMetadata(NodeList<Annotation> metadata) {
    // If there are multiple annotations, they are always on their own lines,
    // even the last.
    if (metadata.length > 1) {
      visitNodes(metadata, between: newline, after: newline);
    } else {
      visitNodes(metadata, between: space, after: newline);
    }
  }

  /// Visit metadata annotations on members.
  ///
  /// These may be on the same line as the member, or on the previous.
  void visitMemberMetadata(NodeList<Annotation> metadata) {
    // If there are multiple annotations, they are always on their own lines,
    // even the last.
    if (metadata.length > 1) {
      visitNodes(metadata, between: newline, after: newline);
    } else {
      visitNodes(metadata, between: space, after: spaceOrNewline);
    }
  }

  /// Visit metadata annotations on parameters and type parameters.
  ///
  /// These are always on the same line as the parameter.
  void visitParameterMetadata(NodeList<Annotation> metadata) {
    // TODO(rnystrom): Allow splitting after annotations?
    visitNodes(metadata, between: space, after: space);
  }

  /// Visit the given function [body], printing a space before it if it's not
  /// empty.
  void visitBody(FunctionBody body) {
    if (body is! EmptyFunctionBody) space();
    visit(body);
  }

  /// Visit a list of [nodes] if not null, optionally separated and/or preceded
  /// and followed by the given functions.
  void visitNodes(NodeList<AstNode> nodes, {before(), between(), after()}) {
    if (nodes == null || nodes.isEmpty) return;

    if (before != null) before();

    visit(nodes.first);
    for (var node in nodes.skip(1)) {
      between();
      visit(node);
    }

    if (after != null) after();
  }

  /// Visit a comma-separated list of [nodes] if not null.
  void visitCommaSeparatedNodes(NodeList<AstNode> nodes, {after()}) {
    if (nodes == null || nodes.isEmpty) return;

    if (after == null) after = space;

    visit(nodes.first);

    for (var node in nodes.skip(1)) {
      token(node.beginToken.previous); // Comma.
      after();
      visit(node);
    }
  }

  /// Visit a [node], and if not null, optionally preceded or followed by the
  /// specified functions.
  void visitNode(AstNode node, {before(), after()}) {
    if (node == null) return;

    if (before != null) before();
    node.accept(this);
    if (after != null) after();
  }

  /// Emit the given [modifier] if it's non null, followed by non-breaking
  /// whitespace.
  void modifier(Token modifier) {
    token(modifier, after: space);
  }

  /// Optionally emit a trailing comma.
  void optionalTrailingComma(Token rightBracket) {
    if (rightBracket.previous.lexeme == ',') {
      token(rightBracket.previous);
    }
  }

  /// Emit a non-breaking space.
  void space() {
    _pending = Whitespace.SPACE;
  }

  /// Emit a single mandatory newline.
  void newline() {
    _pending = Whitespace.NEWLINE;
  }

  /// Emit a two mandatory newlines.
  void twoNewlines() {
    _pending = Whitespace.TWO_NEWLINES;
  }

  /// Allow either a single space or newline to be emitted before the next
  /// non-whitespace token based on whether a newline exists in the source
  /// between the last token and the next one.
  void spaceOrNewline() {
    _pending = Whitespace.SPACE_OR_NEWLINE;
  }

  /// Allow either one or two newlines to be emitted before the next
  /// non-whitespace token based on whether more than one newline exists in the
  /// source between the last token and the next one.
  void oneOrTwoNewlines() {
    _pending = Whitespace.ONE_OR_TWO_NEWLINES;
  }

  /// Outputs a split for [chunk], if given.
  ///
  /// If omitted, defaults to a statement line-break split: one that indents
  /// by two and expands to a space if not split. The param for the split will
  /// have [cost] if given.
  void split({SplitChunk chunk, int cost}) {
    if (chunk == null) {
      if (cost == null) cost = SplitCost.FREE;

      var param = new SplitParam(cost);
      chunk = new SplitChunk(writer.indent + 2, param, " ");
    }

    writer.split(chunk);
  }

  /// Outputs a [SplitChunk] that is the empty string when unsplit and indents
  /// two levels (i.e. a wrapped statement) when split.
  void zeroSplit([int cost = SplitCost.FREE]) {
    var param = new SplitParam(cost);
    writer.split(new SplitChunk(writer.indent + 2, param));
  }

  /// Increase indentation by [n] levels.
  indent([n = 1]) {
    writer.indent += n;
  }

  /// Decrease indentation by [n] levels.
  unindent([n = 1]) {
    writer.indent -= n;
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// Does nothing if [token] is `null`. If [before] is given, it will be
  /// executed before the token is outout. Likewise, [after] will be called
  /// after the token is output.
  void token(Token token, {before(), after()}) {
    if (token == null) return;

    _writePrecedingCommentsAndNewlines(token);

    if (before != null) before();

    append(token.lexeme);

    if (after != null) after();
  }

  /// Writes any formatted whitespace and comments that appear before [token].
  void _writePrecedingCommentsAndNewlines(Token token) {
    // Get the line number of the end of the previous token.
    var previousLine = endLine(token.previous);
    var tokenLine = startLine(token);

    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pending) {
      case Whitespace.SPACE_OR_NEWLINE:
        if (tokenLine - previousLine > 0) {
          _pending = Whitespace.NEWLINE;
        } else {
          _pending = Whitespace.SPACE;
        }
        break;

      case Whitespace.ONE_OR_TWO_NEWLINES:
        if (tokenLine - previousLine > 1) {
          _pending = Whitespace.TWO_NEWLINES;
        } else {
          _pending = Whitespace.NEWLINE;
        }
        break;
    }

    var comment = token.precedingComments;
    if (comment == null) return;

    // Write newlines before the first comment unless it's at the start of the
    // file.
    var allowNewlines = token.previous.type != TokenType.EOF;

    while (true) {
      // Write the whitespace before each comment.
      if (allowNewlines) {
        preserveNewlines(startLine(comment) - previousLine);
      }

      // If the comment is at the very beginning of the line, meaning it's
      // likely a chunk of commented out code, then do not re-indent it.
      if (lineInfo.getLocation(comment.offset).columnNumber == 1) {
        writer.clearIndentation();
      }

      append(comment.toString().trim());

      // After the first comment, we definitely aren't at the start of the
      // file.
      allowNewlines = true;

      previousLine = endLine(comment);
      if (comment.next == null) break;
      comment = comment.next;
    }

    // Only include a space after the last comment (assuming it's on the same
    // line as the next token) if there was already a space there.
    preserveNewlines(tokenLine - endLine(comment),
        allowSpace: comment.end < token.offset);
  }

  /// Preserves *some* of the [numNewlines] that exist between the last text
  /// emitted and the text about to be emitted.
  ///
  /// In most cases, the source code's whitespace is completely ignored.
  /// However, in some cases, the user may add bit of discretionary whitespace.
  /// For example, an extra blank line is allowed between statements, but not
  /// required.
  ///
  /// Only one extra newline may be kept. If there are no newlines between the
  /// last text and the new text, this inserts a space if [allowSpace] is `true`
  /// or otherwise emits nothing.
  void preserveNewlines(int numNewlines, {bool allowSpace: true}) {
    if (numNewlines == 0) {
      // If there are no newlines between the elements, put a single space.
      // This pads a space between items on the same line, like:
      // Put a space after a token and the following comment, as in:
      //
      //     token, /* comment */ /* comment */ token
      //           ^             ^             ^
      if (allowSpace) space();
    } else if (numNewlines == 1) {
      newline();
    } else {
      twoNewlines();
    }
  }

  /// Append the given [string] to the source writer if it's non-null.
  void append(String string) {
    if (string == null || string.isEmpty) return;

    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pending) {
      case Whitespace.SPACE:
        writer.write(" ");
        break;

      case Whitespace.NEWLINE:
        writer.newline();
        break;

      case Whitespace.TWO_NEWLINES:
        writer.newline();
        writer.newline();
        break;

      case Whitespace.SPACE_OR_NEWLINE:
      case Whitespace.ONE_OR_TWO_NEWLINES:
        // We should have pinned these down before getting here.
        assert(false);
    }

    _pending = null;

    writer.write(string);
  }

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int startLine(Token token) => lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int endLine(Token token) => lineInfo.getLocation(token.end).lineNumber;

  String toString() => writer.toString();
}
