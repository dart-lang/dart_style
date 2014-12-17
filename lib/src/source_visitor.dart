// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import '../dart_style.dart';
import 'chunk.dart';
import 'cost.dart';
import 'line_writer.dart';
import 'whitespace.dart';

/// An AST visitor that drives formatting heuristics.
class SourceVisitor implements AstVisitor {
  /// The writer to which the output lines are written.
  final LineWriter _writer;

  /// Cached line info for calculating blank lines.
  LineInfo _lineInfo;

  /// The source being formatted (used in interpolation handling)
  final String _source;

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(DartFormatter formatter, this._lineInfo, this._source,
      StringBuffer outputBuffer)
      : _writer = new LineWriter(formatter, outputBuffer);

  /// Run the visitor on [node], writing all of the formatted output to the
  /// output buffer.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  void run(AstNode node) {
    node.accept(this);

    // Output trailing comments.
    writePrecedingCommentsAndNewlines(node.endToken.next);

    // Finish off the last line.
    _writer.end();
  }

  visitAdjacentStrings(AdjacentStrings node) {
    visitNodes(node.strings, between: split);
  }

  visitAnnotation(Annotation node) {
    token(node.atSign);
    visit(node.name);
    token(node.period);
    visit(node.constructorName);
    visit(node.arguments);
  }

  visitArgumentList(ArgumentList node) {
    // Don't allow any splitting in an empty argument list.
    if (node.arguments.isEmpty &&
        node.rightParenthesis.precedingComments == null) {
      token(node.leftParenthesis);
      token(node.rightParenthesis);
      return;
    }

    // Nest around the parentheses in case there are comments before or after
    // them.
    _writer.nestExpression();
    token(node.leftParenthesis);

    // Allow splitting after "(".
    var cost = Cost.BEFORE_ARGUMENT + node.arguments.length + 1;
    zeroSplit(cost--);

    // See if we kept all of the arguments on the same line.
    _writer.startSpan(Cost.SPLIT_ARGUMENTS);

    // Prefer splitting later arguments over earlier ones.
    visitCommaSeparatedNodes(node.arguments,
        between: () => split(cost: cost--));

    token(node.rightParenthesis);

    // End the span after the ")". That ensures inline block comments after the
    // last argument are part of the span.
    _writer.endSpan();
    _writer.unnest();
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
    _writer.startSpan(Cost.ASSIGNMENT);
    visit(node.rightHandSide);
    _writer.endSpan();
  }

  visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  visitBinaryExpression(BinaryExpression node) {
    _writer.startMultisplit(separable: true);
    _writer.startSpan(Cost.BINARY_OPERATOR);

    // Flatten out a tree/chain of the same operator type. If we split on this
    // operator, we will break all of them.
    traverse(Expression e) {
      if (e is BinaryExpression && e.operator.type == node.operator.type) {
        traverse(e.leftOperand);

        space();
        token(e.operator);
        _writer.multisplit(space: true, nest: true);

        traverse(e.rightOperand);
      } else {
        visit(e);
      }
    }

    traverse(node);

    _writer.endSpan();
    _writer.endMultisplit();
  }

  visitBlock(Block node) {
    _startBody(node.leftBracket);

    visitNodes(node.statements, between: oneOrTwoNewlines, after: newline);

    _endBody(node.rightBracket);
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

    _writer.indent();

    // If there are multiple cascades, they always get their own line, even if
    // they would fit.
    if (node.cascadeSections.length > 1) {
      newline();
      visitNodes(node.cascadeSections, between: newline);
    } else {
      _writer.startMultisplit();
      _writer.multisplit();
      visitNodes(node.cascadeSections, between: () {
        _writer.multisplit();
        _writer.resetNesting();
      });

      _writer.endMultisplit();
    }

    _writer.unindent();
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

    _startBody(node.leftBracket);

    visitNodes(node.members, between: oneOrTwoNewlines, after: newline);

    _endBody(node.rightBracket);
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
    visit(node.scriptTag, after: twoNewlines);

    // Put a blank line between the library tag and the other directives.
    var directives = node.directives;
    if (directives.isNotEmpty && directives.first is LibraryDirective) {
      visitNode(directives.first);
      twoNewlines();

      directives = directives.skip(1);
    }

    visitNodes(directives, between: oneOrTwoNewlines);
    twoNewlines();
    visitNodes(node.declarations, between: oneOrTwoNewlines);
  }

  visitConditionalExpression(ConditionalExpression node) {
    visit(node.condition);
    space();

    _writer.startSpan();
    token(node.question);
    split();
    visit(node.thenExpression);
    space();
    token(node.colon);
    split();
    visit(node.elseExpression);
    _writer.endSpan();
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
    _writer.indent(2);

    if (node.initializers.length > 1) {
      newline();
    } else {
      split();
    }

    token(node.separator); // ":".
    space();

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);

        // Indent subsequent fields one more so they line up with the first
        // field following the ":":
        //
        // Foo()
        //     : first,
        //       second;
        if (i == 1) _writer.indent();
        newline();
      }

      node.initializers[i].accept(this);
    }

    // If there were multiple fields, discard their extra indentation.
    if (node.initializers.length > 1) _writer.unindent();

    _writer.unindent(2);
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
    split();
    _writer.startSpan();
    visit(node.expression);
    token(node.semicolon);
    _writer.endSpan();
  }

  visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    token(node.semicolon);
  }

  visitExtendsClause(ExtendsClause node) {
    split(cost: Cost.BEFORE_EXTENDS);
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

    // TODO(rnystrom): Put a span here similar to ArgumentList to try to keep
    // parameters together.

    if (node.parameters.isNotEmpty) {
      var groupEnd;

      // Allow splitting after the "(" but not for lambdas.
      if (node.parent is! FunctionExpression ||
          (node.parent as FunctionExpression).body is! ExpressionFunctionBody) {
        zeroSplit(Cost.BEFORE_ARGUMENT);
      }

      for (var i = 0; i < node.parameters.length; i++) {
        var parameter = node.parameters[i];
        if (i > 0) {
          append(',');
          // Prefer splitting later parameters over earlier ones.
          split(cost: Cost.BEFORE_ARGUMENT + node.parameters.length + 1 - i);
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
    token(node.ifKeyword);
    space();
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);

    space();
    visit(node.thenStatement);

    if (node.elseStatement != null) {
      if (node.thenStatement is Block) {
        space();
      } else {
        // Corner case where an else follows a single-statement then clause.
        // This is against the style guide, but we still need to handle it. If
        // it happens, put the else on the next line.
        newline();
      }

      token(node.elseKeyword);
      space();
      visit(node.elseStatement);
    }
  }

  visitImplementsClause(ImplementsClause node) {
    split(cost: Cost.BEFORE_IMPLEMENTS);
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
    token(node.leftBracket);
    visit(node.expression);
    token(node.rightBracket);
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
    _visitCollectionLiteral(
        node, node.leftBracket, node.elements, node.rightBracket);
  }

  visitMapLiteral(MapLiteral node) {
    _visitCollectionLiteral(
        node, node.leftBracket, node.entries, node.rightBracket);
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
    // TODO(rnystrom): Do we need to handle cascdes here?

    // If we have a single method call, allow it to split at "." but don't
    // require it to if the whole expression is multiline. For example:
    //
    //     receiver.method(
    //         some, very, long, argument, list);
    if (node.target is! MethodInvocation) {
      if (node.period != null) {
        visit(node.target);
        zeroSplit();
        token(node.period);
      }

      visit(node.methodName);
      visit(node.argumentList);
      return;
    }

    // With a chain of method calls like `foo.bar.baz.bang`, they either all
    // split or none of them do.
    var startedMultisplit = false;

    // Recursively walk the chain of method calls.
    var depth = 0;
    visitInvocation(invocation) {
      depth++;
      var hasTarget = true;

      if (invocation.target is MethodInvocation) {
        visitInvocation(invocation.target);
      } else if (invocation.period != null) {
        visit(invocation.target);
      } else {
        hasTarget = false;
      }

      if (hasTarget) {
        // Don't start the multisplit until after the first target. This
        // ensures we don't get tripped up by newlines or comments before the
        // first target.
        if (!startedMultisplit) {
          _writer.startMultisplit(cost: Cost.BEFORE_PERIOD, separable: true);
          startedMultisplit = true;
        }

        _writer.multisplit(nest: true);
        token(invocation.period);
      }

      visit(invocation.methodName);

      // Stop the multisplit after the last call, but before it's arguments.
      // That allows unsplit chains where the last argument list wraps, like:
      //
      //     foo().bar().baz(
      //         argument, list);
      depth--;
      if (depth == 0 && startedMultisplit) _writer.endMultisplit();

      visit(invocation.argumentList);
    }

    visitInvocation(node);
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
    _writer.nestExpression();
    visit(node.expression);
    _writer.unnest();
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
    token(node.keyword);
    if (node.expression != null) {
      space();
      visit(node.expression);
    }
    token(node.semicolon);
  }

  visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it.
    append(node.scriptTag.lexeme.trim());
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
    writePrecedingCommentsAndNewlines(node.beginToken);
    append(_source.substring(node.beginToken.offset, node.endToken.end));
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

    _writer.indent();
    // TODO(rnystrom): Allow inline cases?
    newline();

    visitNodes(node.statements, between: oneOrTwoNewlines);
    _writer.unindent();
  }

  visitSwitchDefault(SwitchDefault node) {
    visitNodes(node.labels, between: space, after: space);
    token(node.keyword);
    token(node.colon);

    _writer.indent();
    // TODO(rnystrom): Allow inline cases?
    newline();

    visitNodes(node.statements, between: oneOrTwoNewlines);
    _writer.unindent();
  }

  visitSwitchStatement(SwitchStatement node) {
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    visit(node.expression);
    token(node.rightParenthesis);
    space();
    token(node.leftBracket);
    _writer.indent();
    newline();

    visitNodes(node.members, between: oneOrTwoNewlines, after: newline);
    token(node.rightBracket, before: () {
      _writer.unindent();
      newline();
    });
  }

  visitSymbolLiteral(SymbolLiteral node) {
    token(node.poundSign);
    var components = node.components;
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
    visitDeclarationMetadata(node.metadata);
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
    split(cost: Cost.ASSIGNMENT);
    _writer.startSpan(Cost.ASSIGNMENT_SPAN);
    visit(node.initializer);
    _writer.endSpan();
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
      _writer.indent(2);

      for (var variable in node.variables.skip(1)) {
        token(variable.beginToken.previous); // Comma.
        newline();

        visit(variable);
      }

      _writer.unindent(2);
      return;
    }

    // Use a single param for all of the splits. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    var param = new SplitParam();
    // TODO(rnystrom): Should use a multisplit here.

    visitCommaSeparatedNodes(node.variables, between: () {
      split(param: param);
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
    if (node.body is! EmptyStatement) space();
    visit(node.body);
  }

  visitWithClause(WithClause node) {
    split(cost: Cost.BEFORE_WITH);
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
  ///
  /// If [node] is not `null`, invokes [after] if given after visiting the node.
  void visit(AstNode node, {void after()}) {
    if (node == null) return;

    node.accept(this);

    if (after != null) after();
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
  void visitNodes(Iterable<AstNode> nodes, {before(), between(), after()}) {
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
  void visitCommaSeparatedNodes(Iterable<AstNode> nodes, {between()}) {
    if (nodes == null || nodes.isEmpty) return;

    if (between == null) between = space;

    visit(nodes.first);

    for (var node in nodes.skip(1)) {
      token(node.beginToken.previous); // Comma.
      between();
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

  /// Visits the collection literal [node] whose body starts with [leftBracket],
  /// ends with [rightBracket] and contains [elements].
  void _visitCollectionLiteral(TypedLiteral node, Token leftBracket,
      Iterable<AstNode> elements, Token rightBracket) {
    modifier(node.constKeyword);
    visitNode(node.typeArguments);

    _startBody(leftBracket);

    visitCommaSeparatedNodes(elements, between: () {
      _writer.multisplit(space: true);
      _writer.resetNesting();
    });

    optionalTrailingComma(rightBracket);
    _endBody(rightBracket);
  }

  /// Writes an opening bracket token ("(", "{", "[") and handles indenting and
  /// starting the multisplit it contains.
  void _startBody(Token leftBracket) {
    token(leftBracket);

    // Indent the body.
    _writer.startMultisplit();
    _writer.indent();

    // Split after the bracket.
    _writer.multisplit();
  }

  /// Writes a closing bracket token (")", "}", "]") and handles unindenting
  /// and ending the multisplit it contains.
  ///
  /// Used for blocks, other curly bodies, and collection literals.
  void _endBody(Token rightBracket) {
    _writer.resetNesting();

    token(rightBracket, before: () {
      // Split before the closing bracket character.
      _writer.unindent();
      _writer.multisplit();
    }, after: () {
      _writer.endMultisplit();
    });
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
    _writer.writeWhitespace(Whitespace.SPACE);
  }

  /// Emit a single mandatory newline.
  void newline() {
    _writer.writeWhitespace(Whitespace.NEWLINE);
  }

  /// Emit a two mandatory newlines.
  void twoNewlines() {
    _writer.writeWhitespace(Whitespace.TWO_NEWLINES);
  }

  /// Allow either a single space or newline to be emitted before the next
  /// non-whitespace token based on whether a newline exists in the source
  /// between the last token and the next one.
  void spaceOrNewline() {
    _writer.writeWhitespace(Whitespace.SPACE_OR_NEWLINE);
  }

  /// Allow either one or two newlines to be emitted before the next
  /// non-whitespace token based on whether more than one newline exists in the
  /// source between the last token and the next one.
  void oneOrTwoNewlines() {
    _writer.writeWhitespace(Whitespace.ONE_OR_TWO_NEWLINES);
  }

  /// Writes a single-space split with the given [cost] or [param].
  ///
  /// If [param] is omitted, defaults to a new param with [cost]. If [cost] is
  /// omitted, defaults to [Cost.CHEAP].
  void split({int cost, SplitParam param}) {
    _writer.writeSplit(cost: cost, param: param, space: true);
  }

  /// Writes a split with [cost] that is the empty string when unsplit.
  void zeroSplit([int cost]) {
    _writer.writeSplit(cost: cost);
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// Does nothing if [token] is `null`. If [before] is given, it will be
  /// executed before the token is outout. Likewise, [after] will be called
  /// after the token is output.
  void token(Token token, {before(), after()}) {
    if (token == null) return;

    writePrecedingCommentsAndNewlines(token);

    if (before != null) before();

    _writer.write(token.lexeme);

    if (after != null) after();
  }

  /// Writes all formatted whitespace and comments that appear before [token].
  void writePrecedingCommentsAndNewlines(Token token) {
    var comment = token.precedingComments;

    // For performance, avoid calculating newlines between tokens unless
    // actually needed.
    if (comment == null) {
      if (_writer.needsToPreserveNewlines) {
        _writer.preserveNewlines(_startLine(token) - _endLine(token.previous));
      }
      return;
    }

    var previousLine = _endLine(token.previous);
    var tokenLine = _startLine(token);

    var comments = [];
    while (comment != null) {
      var commentLine = _startLine(comment);

      // Don't preserve newlines at the top of the file.
      if (comment == token.precedingComments &&
          token.previous.type == TokenType.EOF) {
        previousLine = commentLine;
      }

      comments.add(new SourceComment(comment.toString().trim(),
          commentLine - previousLine,
          isLineComment: comment.type == TokenType.SINGLE_LINE_COMMENT,
          isStartOfLine: _startColumn(comment) == 1));

      previousLine = _endLine(comment);
      comment = comment.next;
    }

    _writer.writeComments(comments, tokenLine - previousLine, token.lexeme);
  }

  // TODO(rnystrom): Eliminate this. It can cause comments to be discarded.
  /// Append the given [string] to the source writer if it's non-null.
  void append(String string) {
    if (string == null || string.isEmpty) return;

    _writer.write(string);
  }

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => _lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => _lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      _lineInfo.getLocation(token.offset).columnNumber;
}
