// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import '../dart_style.dart';
import 'chunk.dart';
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
    visit(node);

    // Output trailing comments.
    writePrecedingCommentsAndNewlines(node.endToken.next);

    // Finish off the last line.
    _writer.end();
  }

  visitAdjacentStrings(AdjacentStrings node) {
    visitNodes(node.strings, between: spaceOrNewline);
  }

  visitAnnotation(Annotation node) {
    token(node.atSign);
    visit(node.name);
    token(node.period);
    visit(node.constructorName);
    visit(node.arguments);
  }

  /// Visits an argument list.
  ///
  /// This is a bit complex to handle the rules for formatting positional and
  /// named arguments. The goals, in rough order of descending priority are:
  ///
  /// 1. Keep everything on the first line.
  /// 2. Keep the named arguments together on the next line.
  /// 3. Keep everything together on the second line.
  /// 4. Split between one or more positional arguments, trying to keep as many
  ///    on earlier lines as possible.
  /// 5. Split the named arguments each onto their own line.
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
    var lastParam = zeroSplit();

    // Try to keep the positional arguments together.
    _writer.startSpan();

    var i = 0;
    for (; i < node.arguments.length; i++) {
      var argument = node.arguments[i];

      if (argument is NamedExpression) break;

      visit(argument);

      // Write the trailing comma and split.
      if (i < node.arguments.length - 1) {
        token(argument.endToken.next);

        // If there are both positional and named arguments, only try to keep
        // the positional ones together.
        if (node.arguments[i + 1] is NamedExpression) _writer.endSpan();

        // Positional arguments split independently.
        lastParam = split();
      }
    }

    // If there are named arguments, write them.
    if (i < node.arguments.length) {
      // Named arguments all split together, but not before the first. This
      // allows all of the named arguments to get pushed to the next line, but
      // stay together.
      var multisplitParam = _writer.startMultisplit(separable: true);

      // However, if they *do* all split, we want to split before the first one
      // too. This disallows:
      //
      //     method(first: 1,
      //         second: 2,
      //         third: 3);
      multisplitParam.implies.add(lastParam);

      for (; i < node.arguments.length; i++) {
        var argument = node.arguments[i];

        visit(argument);

        // Write the trailing comma and split.
        if (i < node.arguments.length - 1) {
          token(argument.endToken.next);

          _writer.multisplit(nest: true, space: true);
        }
      }

      token(node.rightParenthesis);

      // If there were no positional arguments, the span covers the named ones,
      // so end it here.
      if (node.arguments.first is NamedExpression) _writer.endSpan();

      _writer.endMultisplit();
    } else {
      token(node.rightParenthesis);

      // Keep the positional span past the ")" to include comments after the
      // last argument.
      _writer.endSpan();
    }

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
    _simpleStatement(node, () {
      token(node.keyword);
      token(node.leftParenthesis);
      zeroSplit();
      visit(node.condition);
      token(node.rightParenthesis);
    });
  }

  visitAssignmentExpression(AssignmentExpression node) {
    visit(node.leftHandSide);
    space();
    token(node.operator);
    split(Cost.ASSIGNMENT);
    _writer.startSpan();
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
    _writer.startSpan();
    _writer.nestExpression();

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

    _writer.unnest();
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
    _simpleStatement(node, () {
      token(node.keyword);
      visit(node.label, before: space);
    });
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
      visitNodes(node.cascadeSections, between: _writer.multisplit);

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

    _writer.nestExpression();
    modifier(node.abstractKeyword);
    token(node.classKeyword);
    space();
    visit(node.name);
    visit(node.typeParameters);
    visit(node.extendsClause);
    visit(node.withClause);
    visit(node.implementsClause);
    visit(node.nativeClause, before: space);
    space();

    _writer.unnest();
    _startBody(node.leftBracket);

    visitNodes(node.members, between: oneOrTwoNewlines, after: newline);

    _endBody(node.rightBracket);
  }

  visitClassTypeAlias(ClassTypeAlias node) {
    visitDeclarationMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.abstractKeyword);
      token(node.keyword);
      space();
      visit(node.name);
      visit(node.typeParameters);
      space();
      token(node.equals);
      space();
      visit(node.superclass);
      visit(node.withClause);
      visit(node.implementsClause);
    });
  }

  visitComment(Comment node) => null;

  visitCommentReference(CommentReference node) => null;

  visitCompilationUnit(CompilationUnit node) {
    visit(node.scriptTag);

    // Put a blank line between the library tag and the other directives.
    var directives = node.directives;
    if (directives.isNotEmpty && directives.first is LibraryDirective) {
      visit(directives.first);
      twoNewlines();

      directives = directives.skip(1);
    }

    visitNodes(directives, between: oneOrTwoNewlines);
    visitNodes(node.declarations,
        before: twoNewlines, between: oneOrTwoNewlines);
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

    _writer.nestExpression();
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

    _writer.unnest();

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
    _simpleStatement(node, () {
      token(node.keyword);
      visit(node.label, before: space);
    });
  }

  visitDeclaredIdentifier(DeclaredIdentifier node) {
    modifier(node.keyword);
    visit(node.type, after: space);
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
      visit(node.defaultValue, before: space);
    }
  }

  visitDoStatement(DoStatement node) {
    _simpleStatement(node, () {
      token(node.doKeyword);
      space();
      visit(node.body);
      space();
      token(node.whileKeyword);
      space();
      token(node.leftParenthesis);
      zeroSplit();
      visit(node.condition);
      token(node.rightParenthesis);
    });
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

  visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    throw new UnimplementedError("Enum formatting is not implemented yet.");
  }

  visitEnumDeclaration(EnumDeclaration node) {
    throw new UnimplementedError("Enum formatting is not implemented yet.");
  }

  visitExportDirective(ExportDirective node) {
    visitDeclarationMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.uri);
      _visitCombinators(node.combinators);
    });
  }

  visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _simpleStatement(node, () {
      // The "async" or "sync" keyword.
      token(node.keyword, after: space);

      // Try to keep the "(...) => " with the start of the body for anonymous
      // functions.
      if (_isLambda(node)) _writer.startSpan();

      token(node.functionDefinition); // "=>".
      split();

      if (_isLambda(node)) _writer.endSpan();

      _writer.startSpan();
      visit(node.expression);
      _writer.endSpan();
    });
  }

  visitExpressionStatement(ExpressionStatement node) {
    _simpleStatement(node, () {
      visit(node.expression);
    });
  }

  visitExtendsClause(ExtendsClause node) {
    split();
    token(node.keyword);
    space();
    visit(node.superclass);
  }

  visitFieldDeclaration(FieldDeclaration node) {
    visitMemberMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.staticKeyword);
      visit(node.fields);
    });
  }

  visitFieldFormalParameter(FieldFormalParameter node) {
    token(node.keyword, after: space);
    visit(node.type, after: space);
    token(node.thisToken);
    token(node.period);
    visit(node.identifier);
    visit(node.parameters);
  }

  visitForEachStatement(ForEachStatement node) {
    _writer.nestExpression();
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);
    if (node.loopVariable != null) {
      visit(node.loopVariable);
    } else {
      visit(node.identifier);
    }
    split();
    token(node.inKeyword);
    space();
    visit(node.iterator);
    token(node.rightParenthesis);
    space();
    visit(node.body);
    _writer.unnest();
  }

  visitFormalParameterList(FormalParameterList node) {
    token(node.leftParenthesis);

    // Allow splitting after the "(" in non-empty parameter lists, but not for
    // lambdas.
    if ((node.parameters.isNotEmpty ||
            node.rightParenthesis.precedingComments != null) &&
        !_isLambda(node)) {
      zeroSplit();
    }

    // Try to keep the parameters together.
    _writer.startSpan();

    var inOptionalParams = false;
    for (var i = 0; i < node.parameters.length; i++) {
      var parameter = node.parameters[i];
      var inFirstOptional =
          !inOptionalParams && parameter is DefaultFormalParameter;

      // Preceding comma.
      if (i > 0) token(node.parameters[i - 1].endToken.next);

      // Don't try to keep optional parameters together with mandatory ones.
      if (inFirstOptional) _writer.endSpan();

      if (i > 0) split();

      if (inFirstOptional) {
        // Do try to keep optional parameters with each other.
        _writer.startSpan();

        // "[" or "{" for optional parameters.
        token(node.leftDelimiter);

        inOptionalParams = true;
      }

      visit(parameter);
    }

    // "]" or "}" for optional parameters.
    token(node.rightDelimiter);

    token(node.rightParenthesis);
    _writer.endSpan();
  }

  visitForStatement(ForStatement node) {
    _writer.nestExpression();
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);

    _writer.startMultisplit();

    // The initialization clause.
    if (node.initialization != null) {
      visit(node.initialization);
    } else {
      if (node.variables == null) {
        space();
      } else {
        // Indent split variables more so they aren't at the same level
        // as the rest of the loop clauses.
        _writer.indent(4);

        var declaration = node.variables;
        visitDeclarationMetadata(declaration.metadata);
        modifier(declaration.keyword);
        visit(declaration.type, after: space);

        visitCommaSeparatedNodes(declaration.variables, between: () {
          _writer.multisplit(space: true, nest: true);
        });

        _writer.unindent(4);
      }
    }

    token(node.leftSeparator);
    _writer.multisplit(nest: true, space: true);

    // The condition clause.
    visit(node.condition);
    token(node.rightSeparator);

    // The update clause.
    if (node.updaters != null) {
      _writer.multisplit(nest: true, space: true);
      visitCommaSeparatedNodes(node.updaters,
          between: () => _writer.multisplit(nest: true, space: true));
    }

    token(node.rightParenthesis);
    _writer.endMultisplit();
    _writer.unnest();

    // The body.
    if (node.body is! EmptyStatement) space();
    visit(node.body);
  }

  visitFunctionDeclaration(FunctionDeclaration node) {
    visitMemberMetadata(node.metadata);

    _writer.nestExpression();
    modifier(node.externalKeyword);
    visit(node.returnType, after: space);
    modifier(node.propertyKeyword);
    visit(node.name);
    visit(node.functionExpression);
    _writer.unnest();
  }

  visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    visit(node.functionDeclaration);
  }

  visitFunctionExpression(FunctionExpression node) {
    visit(node.parameters);
    visitBody(node.body);
  }

  visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    visit(node.function);
    visit(node.argumentList);
  }

  visitFunctionTypeAlias(FunctionTypeAlias node) {
    visitDeclarationMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.returnType, after: space);
      visit(node.name);
      visit(node.typeParameters);
      visit(node.parameters);
    });
  }

  visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    visit(node.returnType, after: space);

    // Try to keep the function's parameters with its name.
    _writer.startSpan();
    visit(node.identifier);
    visit(node.parameters);
    _writer.endSpan();
  }

  visitHideCombinator(HideCombinator node) {
    _visitCombinator(node.keyword, node.hiddenNames);
  }

  visitIfStatement(IfStatement node) {
    _writer.nestExpression();
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

    _writer.unnest();
  }

  visitImplementsClause(ImplementsClause node) {
    split();
    token(node.keyword);
    space();
    visitCommaSeparatedNodes(node.interfaces);
  }

  visitImportDirective(ImportDirective node) {
    visitDeclarationMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.uri);
      token(node.deferredToken, before: space);
      token(node.asToken, before: split, after: space);
      visit(node.prefix);
      _visitCombinators(node.combinators);
    });
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

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.name);
    });
  }

  visitLibraryIdentifier(LibraryIdentifier node) {
    visit(node.components.first);
    for (var component in node.components.skip(1)) {
      token(component.beginToken.previous); // "."
      visit(component);
    }
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
    split();
    visit(node.value);
  }

  visitMethodDeclaration(MethodDeclaration node) {
    visitMemberMetadata(node.metadata);

    _writer.nestExpression();
    modifier(node.externalKeyword);
    modifier(node.modifierKeyword);
    visit(node.returnType, after: space);
    modifier(node.propertyKeyword);
    modifier(node.operatorKeyword);
    visit(node.name);
    if (!node.isGetter) visit(node.parameters);

    _writer.unnest();

    visitBody(node.body);
  }

  visitMethodInvocation(MethodInvocation node) {
    // With a chain of method calls like `foo.bar.baz.bang`, they either all
    // split or none of them do.
    var startedMultisplit = false;

    // Try to keep the entire method chain one line.
    _writer.startSpan();

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
          _writer.startMultisplit(separable: true);
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
    _writer.endSpan();
  }

  visitNamedExpression(NamedExpression node) {
    visit(node.name);
    visit(node.expression, before: space);
  }

  visitNativeClause(NativeClause node) {
    token(node.keyword);
    space();
    visit(node.name);
  }

  visitNativeFunctionBody(NativeFunctionBody node) {
    _simpleStatement(node, () {
      token(node.nativeToken);
      space();
      visit(node.stringLiteral);
    });
  }

  visitNullLiteral(NullLiteral node) {
    token(node.literal);
  }

  visitParenthesizedExpression(ParenthesizedExpression node) {
    _writer.nestExpression();
    token(node.leftParenthesis);
    visit(node.expression);
    _writer.unnest();
    token(node.rightParenthesis);
  }

  visitPartDirective(PartDirective node) {
    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.uri);
    });
  }

  visitPartOfDirective(PartOfDirective node) {
    _simpleStatement(node, () {
      token(node.keyword);
      space();
      token(node.ofToken);
      space();
      visit(node.libraryName);
    });
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
    _writer.startSpan();

    token(node.keyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    _writer.endSpan();
  }

  visitRethrowExpression(RethrowExpression node) {
    token(node.keyword);
  }

  visitReturnStatement(ReturnStatement node) {
    _simpleStatement(node, () {
      token(node.keyword);
      if (node.expression != null) {
        space();
        visit(node.expression);
      }
    });
  }

  visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it. Since the script tag must
    // come at the top of the file, we don't have to worry about preceding
    // comments or whitespace.
    _writer.write(node.scriptTag.lexeme.trim());
    oneOrTwoNewlines();
  }

  visitShowCombinator(ShowCombinator node) {
    _visitCombinator(node.keyword, node.shownNames);
  }

  visitSimpleFormalParameter(SimpleFormalParameter node) {
    visitParameterMetadata(node.metadata);
    modifier(node.keyword);
    visit(node.type, after: space);
    visit(node.identifier);
  }

  visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  visitSimpleStringLiteral(SimpleStringLiteral node) {
    token(node.literal);
  }

  visitStringInterpolation(StringInterpolation node) {
    // Since we output the interpolated text manually, ensure we include any
    // preceding stuff first.
    writePrecedingCommentsAndNewlines(node.beginToken);

    // Ensure that interpolated strings don't get broken up by manually
    // outputting them as an unformatted substring of the source.
    _writer.write(_source.substring(node.beginToken.offset, node.endToken.end));
  }

  visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _writer.startSpan();

    token(node.keyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    _writer.endSpan();
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
    _writer.nestExpression();
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    zeroSplit();
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
    _writer.unnest();
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

    _simpleStatement(node, () {
      visit(node.variables);
    });
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
    split(Cost.ASSIGNMENT);
    _writer.startSpan();
    visit(node.initializer);
    _writer.endSpan();
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    visitDeclarationMetadata(node.metadata);
    modifier(node.keyword);
    visit(node.type, after: space);

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

    // Use a multisplit between all of the variables. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    _writer.startMultisplit();
    visitCommaSeparatedNodes(node.variables, between: () {
      _writer.multisplit(space: true, nest: true);
    });
    _writer.endMultisplit();
  }

  visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    _simpleStatement(node, () {
      visit(node.variables);
    });
  }

  visitWhileStatement(WhileStatement node) {
    _writer.nestExpression();
    token(node.keyword);
    space();
    token(node.leftParenthesis);
    zeroSplit();
    visit(node.condition);
    token(node.rightParenthesis);
    if (node.body is! EmptyStatement) space();
    visit(node.body);
    _writer.unnest();
  }

  visitWithClause(WithClause node) {
    split();
    token(node.withKeyword);
    space();
    visitCommaSeparatedNodes(node.mixinTypes);
  }

  visitYieldStatement(YieldStatement node) {
    _simpleStatement(node, () {
      token(node.yieldKeyword);
      token(node.star);
      space();
      visit(node.expression);
    });
  }

  /// Visit a [node], and if not null, optionally preceded or followed by the
  /// specified functions.
  void visit(AstNode node, {void before(), void after()}) {
    if (node == null) return;

    if (before != null) before();

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
      if (between != null) between();
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

  /// Visits the collection literal [node] whose body starts with [leftBracket],
  /// ends with [rightBracket] and contains [elements].
  void _visitCollectionLiteral(TypedLiteral node, Token leftBracket,
      Iterable<AstNode> elements, Token rightBracket) {
    modifier(node.constKeyword);
    visit(node.typeArguments);

    _startBody(leftBracket);

    // Each list element takes at least 3 characters (one character for the
    // element, one for the comma, one for the space), so force it to split if
    // we know that won't fit.
    if (elements.length > _writer.pageWidth ~/ 3) _writer.preemptMultisplits();

    for (var element in elements) {
      if (element != elements.first) _writer.multisplit(space: true);

      _writer.nestExpression();

      visit(element);

      // The comma after the element.
      if (element.endToken.next.lexeme == ",") token(element.endToken.next);

      _writer.unnest();
    }

    _endBody(rightBracket);
  }

  /// Visits a list of [combinators] following an "import" or "export"
  /// directive. Combinators can be split in a few different ways:
  ///
  ///     // All on one line:
  ///     import 'animals.dart' show Ant hide Cat;
  ///
  ///     // Wrap before each keyword:
  ///     import 'animals.dart'
  ///         show Ant, Baboon
  ///         hide Cat;
  ///
  ///     // Wrap either or both of the name lists:
  ///     import 'animals.dart'
  ///         show
  ///             Ant,
  ///             Baboon
  ///         hide Cat;
  ///
  /// Multisplits are used here to specifically avoid a few undesirable
  /// combinations:
  ///
  ///     // Wrap list but not keyword:
  ///     import 'animals.dart' show
  ///             Ant,
  ///             Baboon
  ///         hide Cat;
  ///
  ///     // Wrap one keyword but not both:
  ///     import 'animals.dart'
  ///         show Ant, Baboon hide Cat;
  ///
  /// This ensures that when any wrapping occurs, the keywords are always at
  /// the beginning of the line.
  void _visitCombinators(NodeList<Combinator> combinators) {
    if (combinators.isEmpty) return;

    _writer.startMultisplit();
    visitNodes(combinators);
    _writer.endMultisplit();
  }

  /// Visits a [HideCombinator] or [ShowCombinator] starting with [keyword] and
  /// containing [names].
  ///
  /// This assumes it has been called from within the [Multisplit] created by
  /// [_visitCombinators].
  void _visitCombinator(Token keyword, NodeList<SimpleIdentifier> names) {
    // Allow splitting after the keyword.
    _writer.multisplit(space: true, nest: true);

    _writer.nestExpression();
    token(keyword);

    _writer.startMultisplit();
    _writer.multisplit(nest: true, space: true);
    visitCommaSeparatedNodes(names,
        between: () => _writer.multisplit(nest: true, space: true));

    _writer.unnest();
    _writer.endMultisplit();
  }

  /// Writes the simple statement or semicolon-delimited top-level declaration.
  ///
  /// Handles nesting if a line break occurs in the statement and writes the
  /// terminating semicolon. Invokes [body] which should write statement itself.
  void _simpleStatement(AstNode node, body()) {
    _writer.nestExpression();
    body();

    // TODO(rnystrom): Can the analyzer move "semicolon" to some shared base
    // type?
    token((node as dynamic).semicolon);
    _writer.unnest();
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
    token(rightBracket, before: () {
      // Split before the closing bracket character.
      _writer.unindent();
      _writer.multisplit();
    }, after: () {
      _writer.endMultisplit();
    });
  }

  /// Returns `true` if [node] is immediately contained within an anonymous
  /// [FunctionExpression].
  bool _isLambda(AstNode node) =>
      node.parent is FunctionExpression &&
      node.parent.parent is! FunctionDeclaration;

  /// Emit the given [modifier] if it's non null, followed by non-breaking
  /// whitespace.
  void modifier(Token modifier) {
    token(modifier, after: space);
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

  /// Writes a single-space split with the given [cost].
  ///
  /// If [cost] is omitted, defaults to [Cost.NORMAL]. Returns the newly created
  /// [SplitParam].
  SplitParam split([int cost]) => _writer.writeSplit(cost: cost, space: true);

  /// Writes a split that is the empty string when unsplit.
  ///
  /// Returns the newly created [SplitParam].
  SplitParam zeroSplit() => _writer.writeSplit();

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

    // Corner case! The analyzer includes the "\n" in the script tag's lexeme,
    // which means it appears to be one line later than it is. That causes a
    // comment following it to appear to be on the same line. Fix that here by
    // correcting the script tag's line.
    if (token.previous.type == TokenType.SCRIPT_TAG) previousLine--;

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

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => _lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => _lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      _lineInfo.getLocation(token.offset).columnNumber;
}
