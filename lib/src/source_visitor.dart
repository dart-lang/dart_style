// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'dart_formatter.dart';
import 'chunk.dart';
import 'line_writer.dart';
import 'rule.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// An AST visitor that drives formatting heuristics.
class SourceVisitor implements AstVisitor {
  final DartFormatter _formatter;

  /// The writer to which the output lines are written.
  final LineWriter _writer;

  /// Cached line info for calculating blank lines.
  LineInfo _lineInfo;

  /// The source being formatted.
  final SourceCode _source;

  /// `true` if the visitor has written past the beginning of the selection in
  /// the original source text.
  bool _passedSelectionStart = false;

  /// `true` if the visitor has written past the end of the selection in the
  /// original source text.
  bool _passedSelectionEnd = false;

  /// The character offset of the end of the selection, if there is a selection.
  ///
  /// This is calculated and cached by [_findSelectionEnd].
  int _selectionEnd;

  /// The number out oustanding calls to [_startNestBodies].
  int _nestBodiesCount = 0;

  /// The rule that should be used for the contents of a literal body that are
  /// about to be written.
  ///
  /// This is set by [visitArgumentList] to ensure that all body arguments share
  /// a rule.
  ///
  /// If `null`, a literal body creates its own rule.
  Rule _nextBodyRule;

  /// The span that binds the parameter list of a lambda function argument to
  /// the surrounding argument list.
  OpenSpan _firstFunctionSpan;

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(formatter, this._lineInfo, SourceCode source)
      : _formatter = formatter,
        _source = source,
        _writer = new LineWriter(formatter, source);

  /// Runs the visitor on [node], formatting its contents.
  ///
  /// Returns a [SourceCode] containing the resulting formatted source and
  /// updated selection, if any.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  SourceCode run(AstNode node) {
    visit(node);

    // Output trailing comments.
    writePrecedingCommentsAndNewlines(node.endToken.next);

    // Finish writing and return the complete result.
    return _writer.end();
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
    // Corner case: handle empty argument lists.
    if (node.arguments.isEmpty) {
      token(node.leftParenthesis);

      // If there is a comment inside the parens, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      return;
    }

    // Assumes named arguments follow all positional ones.
    var positionalArgs = node.arguments
        .takeWhile((arg) => arg is! NamedExpression).toList();
    var namedArgs = node.arguments.skip(positionalArgs.length).toList();

    var leadingBodies = 0;
    var trailingBodies = 0;

    var bodies = node.arguments.where(_isBody).toSet();

    for (var argument in node.arguments) {
      if (!bodies.contains(argument)) break;
      leadingBodies++;
    }

    if (leadingBodies != node.arguments.length) {
      for (var argument in node.arguments.reversed) {
        if (!bodies.contains(argument)) break;
        trailingBodies++;
      }
    }

    // If only some of the named arguments are bodies, treat none of them as
    // bodies. Avoids cases like:
    //
    //     function(
    //         a: arg,
    //         b: [
    //       ...
    //     ]);
    if (trailingBodies < namedArgs.length) trailingBodies = 0;

    // Bodies must all be a prefix or suffix of the argument list (and not
    // both).
    if (leadingBodies != bodies.length) leadingBodies = 0;
    if (trailingBodies != bodies.length) trailingBodies = 0;

    // Ignore any bodies in the middle of the argument list.
    if (leadingBodies == 0 && trailingBodies == 0) {
      bodies.clear();
    }

    // If there is just one positional argument, it tends to look weird to
    // split before it, so try not to.
    var singleArgument = positionalArgs.length == 1 && namedArgs.isEmpty;

    if (singleArgument) _writer.startSpan();

    // Corner case: If the first argument to a method is a function, it looks
    // bad if its parameter list gets wrapped to the next line. Bump the cost
    // to try to avoid that. This prefers:
    //
    //     receiver
    //         .method()
    //         .chain((parameter, list) {
    //       ...
    //     });
    //
    // over:
    //
    //     receiver.method().chain(
    //         (parameter, list) {
    //       ...
    //     });
    if (node.arguments.first is FunctionExpression) {
      _firstFunctionSpan = _writer.createSpan();
    }

    // Nest around the parentheses in case there are comments before or after
    // them.
    _writer.nestExpression();
    _writer.startSpan();
    token(node.leftParenthesis);

    var bodyRule = bodies.isNotEmpty
        ? new SimpleRule(cost: Cost.splitBodies)
        : null;

    var rule;

    writeArgument(argument) {
      // If we're about to write a body argument, handle it specially.
      if (bodies.contains(argument)) {
        if (rule != null) rule.beforeBodyArgument();

        // Tell it to use the rule we've already created.
        _nextBodyRule = bodyRule;
      } else {
        _startNestBodies();
      }

      visit(argument);

      if (bodies.contains(argument)) {
        if (rule != null) rule.afterBodyArgument();
      } else {
        _endNestBodies();
      }

      // Write the trailing comma.
      if (argument != node.arguments.last) token(argument.endToken.next);
    }

    // Allow splitting after "(".
    if (positionalArgs.isNotEmpty) {
      if (positionalArgs.length == 1) {
        rule = new SinglePositionalRule(bodyRule);
      } else {
        rule = new MultiplePositionalRule(
            bodyRule, leadingBodies, trailingBodies);
      }

      _writer.startRule(rule);
      rule.beforeArgument(zeroSplit());

      // Try to not split the arguments.
      _writer.startSpan(Cost.positionalArguments);

      for (var argument in positionalArgs) {
        writeArgument(argument);

        // Positional arguments split independently.
        if (argument != positionalArgs.last) {
          rule.beforeArgument(split());
        }
      }

      _writer.endSpan();
      _writer.endRule();
    }

    if (namedArgs.isNotEmpty) {
      var positionalRule = rule;
      rule = new NamedArgsRule(bodyRule, areBodies: trailingBodies > 0);
      _writer.startRule(rule);

      // Let the positional args force the named ones to split.
      if (positionalRule != null) {
        positionalRule.setNamedArgsRule(rule);
      }

      // Split before the first named argument.
      rule.beforeArguments(_writer.split(space: positionalArgs.isNotEmpty));

      for (var argument in namedArgs) {
        writeArgument(argument);

        // Write the split.
        if (argument != namedArgs.last) split();
      }

      _writer.endRule();
    }

    token(node.rightParenthesis);

    _writer.endSpan();
    _writer.unnest();

    if (singleArgument) _writer.endSpan();
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
      soloZeroSplit();
      visit(node.condition);
      token(node.rightParenthesis);
    });
  }

  visitAssignmentExpression(AssignmentExpression node) {
    visit(node.leftHandSide);
    space();
    token(node.operator);
    soloSplit(Cost.assignment);
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
    _writer.startSpan();
    _writer.nestExpression();

    // Note that we have the full precedence table here even though some
    // operators are not associative and so can never chain. In particular,
    // Dart does not allow sequences of comparison or equality operators.
    const operatorPrecedences = const {
      // Multiplicative.
      TokenType.STAR: 13,
      TokenType.SLASH: 13,
      TokenType.TILDE_SLASH: 13,
      TokenType.PERCENT: 13,

      // Additive.
      TokenType.PLUS: 12,
      TokenType.MINUS: 12,

      // Shift.
      TokenType.LT_LT: 11,
      TokenType.GT_GT: 11,

      // "&".
      TokenType.AMPERSAND: 10,

      // "^".
      TokenType.CARET: 9,

      // "|".
      TokenType.BAR: 8,

      // Relational.
      TokenType.LT: 7,
      TokenType.GT: 7,
      TokenType.LT_EQ: 7,
      TokenType.GT_EQ: 7,
      // Note: as, is, and is! have the same precedence but are not handled
      // like regular binary operators since they aren't associative.

      // Equality.
      TokenType.EQ_EQ: 6,
      TokenType.BANG_EQ: 6,

      // Logical and.
      TokenType.AMPERSAND_AMPERSAND: 5,

      // Logical or.
      TokenType.BAR_BAR: 4,
    };

    // Flatten out a tree/chain of the same precedence. If we split on this
    // precedence level, we will break all of them.
    var precedence = operatorPrecedences[node.operator.type];
    assert(precedence != null);

    // Start lazily so we don't force the operator to split if a line comment
    // appears before the first operand.
    _writer.startLazyRule();

    traverse(Expression e) {
      if (e is BinaryExpression &&
          operatorPrecedences[e.operator.type] == precedence) {
        assert(operatorPrecedences[e.operator.type] != null);

        traverse(e.leftOperand);

        space();
        token(e.operator);

        split();
        traverse(e.rightOperand);
      } else {
        visit(e);
      }
    }

    // Bodies as operands to infix operators should always nest like regular
    // operands. (Granted, this case is exceedingly rare in real code.)
    _startNestBodies();

    traverse(node);

    _endNestBodies();

    _writer.unnest();
    _writer.endSpan();
    _writer.endRule();
  }

  visitBlock(Block node) {
    var isBody = node.parent is BlockFunctionBody;

    _startBody(node.leftBracket, isBody: isBody);

    visitNodes(node.statements, between: oneOrTwoNewlines, after: newline);

    _endBody(node.rightBracket, isBody: isBody);
  }

  visitBlockFunctionBody(BlockFunctionBody node) {
    // The "async" or "sync" keyword.
    token(node.keyword);

    // The "*" in "async*" or "sync*".
    token(node.star);
    if (node.keyword != null) space();

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

    // TODO(bob): Force nested blocks here?

    _writer.indent();

    // If there are multiple cascades, they always get their own line, even if
    // they would fit.
    if (node.cascadeSections.length > 1) {
      newline();
      visitNodes(node.cascadeSections, between: newline);
    } else {
      _writer.startRule();
      zeroSplit();
      visitNodes(node.cascadeSections, between: zeroSplit);
      _writer.endRule();
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
    _writer.nestExpression();
    visit(node.condition);

    _writer.startSpan();

    // If we split after one clause in a conditional, always split after both.
    _writer.startRule();
    split();
    token(node.question);
    space();

    _writer.nestExpression();
    visit(node.thenExpression);
    _writer.unnest();

    split();
    token(node.colon);
    space();

    visit(node.elseExpression);

    _writer.endRule();
    _writer.endSpan();
    _writer.unnest();
  }

  visitConstructorDeclaration(ConstructorDeclaration node) {
    visitMemberMetadata(node.metadata);

    modifier(node.externalKeyword);
    modifier(node.constKeyword);
    modifier(node.factoryKeyword);
    visit(node.returnType);
    token(node.period);
    visit(node.name);

    // Make the rule for the ":" span both the preceding parameter list and
    // the entire initialization list. This ensures that we split before the
    // ":" if the parameters and initialization list don't all fit on one line.
    _writer.startRule();

    _visitBody(node.parameters, node.body, () {
      // Check for redirects or initializer lists.
      if (node.redirectedConstructor != null) {
        _visitConstructorRedirects(node);
      } else if (node.initializers.isNotEmpty) {
        _visitConstructorInitializers(node);
      }
    });
  }

  void _visitConstructorRedirects(ConstructorDeclaration node) {
    token(node.separator /* = */, before: space, after: space);
    visitCommaSeparatedNodes(node.initializers);
    visit(node.redirectedConstructor);
  }

  void _visitConstructorInitializers(ConstructorDeclaration node) {
    _writer.indent(2);

    split();
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

    // End the rule for ":" after all of the initializers.
    _writer.endRule();
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
      if (node.separator.type == TokenType.EQ) space();
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
      soloZeroSplit();
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
    visit(node.name);
  }

  visitEnumDeclaration(EnumDeclaration node) {
    visitDeclarationMetadata(node.metadata);

    token(node.keyword);
    space();
    visit(node.name);
    space();

    _startBody(node.leftBracket, space: true);

    visitCommaSeparatedNodes(node.constants, between: split);

    _endBody(node.rightBracket, space: true);
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
      if (_isInLambda(node)) _writer.startSpan();

      token(node.functionDefinition); // "=>".
      soloSplit();

      if (_isInLambda(node)) _writer.endSpan();

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
    soloSplit();
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
    visitParameterMetadata(node.metadata);
    token(node.keyword, after: space);
    visit(node.type, after: space);
    token(node.thisToken);
    token(node.period);
    visit(node.identifier);
    visit(node.parameters);
  }

  visitForEachStatement(ForEachStatement node) {
    _writer.nestExpression();
    token(node.awaitKeyword, after: space);
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);
    if (node.loopVariable != null) {
      visit(node.loopVariable);
    } else {
      visit(node.identifier);
    }
    soloSplit();
    token(node.inKeyword);
    space();
    visit(node.iterable);
    token(node.rightParenthesis);
    space();
    visit(node.body);
    _writer.unnest();
  }

  visitFormalParameterList(FormalParameterList node) {
    // Corner case: empty parameter lists.
    if (node.parameters.isEmpty) {
      token(node.leftParenthesis);

      // If there is a comment, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      return;
    }

    var requiredParams = node.parameters
        .where((param) => param is! DefaultFormalParameter).toList();
    var optionalParams = node.parameters
        .where((param) => param is DefaultFormalParameter).toList();

    _writer.nestExpression();
    token(node.leftParenthesis);

    // If this parameter list is for a lambda argument that we want to avoid
    // splitting, close the span that sticks it to the beginning of the
    // argument list.
    if (_firstFunctionSpan != null) {
      _writer.endSpan(_firstFunctionSpan);
      _firstFunctionSpan = null;
    }

    var rule;
    if (requiredParams.isNotEmpty) {
      if (requiredParams.length > 1) {
        rule = new MultiplePositionalRule(null, 0, 0);
      } else {
        rule = new SinglePositionalRule(null);
      }

      _writer.startRule(rule);
      if (_isInLambda(node)) {
        // Don't allow splitting before the first argument (i.e. right after
        // the bare "(" in a lambda. Instead, just stuff a null chunk in there
        // to avoid confusing the arg rule.
        rule.beforeArgument(null);
      } else {
        // Split before the first argument.
        rule.beforeArgument(zeroSplit());
      }

      for (var param in requiredParams) {
        visit(param);

        // Write the trailing comma.
        if (param != node.parameters.last) token(param.endToken.next);

        if (param != requiredParams.last) rule.beforeArgument(split());
      }

      _writer.endRule();
    }

    if (optionalParams.isNotEmpty) {
      var namedRule = new NamedArgsRule(rule);
      _writer.startRule(namedRule);

      namedRule.beforeArguments(
          _writer.split(space: requiredParams.isNotEmpty));

      // "[" or "{" for optional parameters.
      token(node.leftDelimiter);

      for (var param in optionalParams) {
        visit(param);

        // Write the trailing comma.
        if (param != node.parameters.last) token(param.endToken.next);
        if (param != optionalParams.last) split();
      }

      _writer.endRule();

      // "]" or "}" for optional parameters.
      token(node.rightDelimiter);
    }

    token(node.rightParenthesis);
    _writer.unnest();
  }

  visitForStatement(ForStatement node) {
    _writer.nestExpression();
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);

    _writer.startRule();

    // The initialization clause.
    if (node.initialization != null) {
      visit(node.initialization);
    } else if (node.variables != null) {
      // Indent split variables more so they aren't at the same level
      // as the rest of the loop clauses.
      _writer.indent(4);

      var declaration = node.variables;
      visitDeclarationMetadata(declaration.metadata);
      modifier(declaration.keyword);
      visit(declaration.type, after: space);

      visitCommaSeparatedNodes(declaration.variables, between: () {
        split();
      });

      _writer.unindent(4);
    }

    token(node.leftSeparator);

    // The condition clause.
    if (node.condition != null) split();
    visit(node.condition);
    token(node.rightSeparator);

    // The update clause.
    if (node.updaters.isNotEmpty) {
      split();
      visitCommaSeparatedNodes(node.updaters, between: split);
    }

    token(node.rightParenthesis);
    _writer.endRule();
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
    _visitBody(node.parameters, node.body);
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
    visitParameterMetadata(node.metadata);
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
    _writer.unnest();

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
    soloSplit();
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
      token(node.asToken, before: soloSplit, after: space);
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

    _writer.startSpan();
    token(node.leftBracket);
    _writer.nestExpression();
    soloZeroSplit();
    visit(node.index);
    token(node.rightBracket);
    _writer.unnest();
    _writer.endSpan();
  }

  visitInstanceCreationExpression(InstanceCreationExpression node) {
    _writer.startSpan();
    token(node.keyword);
    space();
    visit(node.constructorName);
    visit(node.argumentList);
    _writer.endSpan();
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
    // Corner case: Splitting inside a list looks bad if there's only one
    // element, so make those more costly.
    var cost = node.elements.length <= 1 ? Cost.singleElementList : Cost.normal;
    _visitCollectionLiteral(
        node, node.leftBracket, node.elements, node.rightBracket, cost);
  }

  visitMapLiteral(MapLiteral node) {
    _visitCollectionLiteral(
        node, node.leftBracket, node.entries, node.rightBracket);
  }

  visitMapLiteralEntry(MapLiteralEntry node) {
    visit(node.key);
    token(node.separator);
    soloSplit();
    visit(node.value);
  }

  visitMethodDeclaration(MethodDeclaration node) {
    visitMemberMetadata(node.metadata);

    modifier(node.externalKeyword);
    modifier(node.modifierKeyword);
    visit(node.returnType, after: space);
    modifier(node.propertyKeyword);
    modifier(node.operatorKeyword);
    visit(node.name);

    _visitBody(node.parameters, node.body);
  }

  visitMethodInvocation(MethodInvocation node) {
    // If there's no target, this is a "bare" function call like "foo(1, 2)",
    // or a section in a cascade. Handle this case specially.
    if (node.target == null) {
      // Try to keep the entire method invocation one line.
      _writer.startSpan();
      _writer.nestExpression();

      // This will be non-null for cascade sections.
      token(node.period);
      token(node.methodName.token);
      visit(node.argumentList);

      _writer.unnest();
      _writer.endSpan();
      return;
    }

    // Otherwise, it's a dotted method call. We want to format a chain of
    // method calls holistically, so flatten the tree of calls into a single
    // list.
    var target;
    var invocations = [];

    flatten(expression) {
      target = expression;

      if (expression is MethodInvocation && expression.target != null) {
        flatten(expression.target);
        invocations.add(expression);
      }
    }

    // Recursively walk the chain of method calls.
    flatten(node);

    _startNestBodies();

    // Try to keep the entire method invocation one line.
    _writer.startSpan();
    _writer.nestExpression();

    visit(target);

    // With a chain of method calls like `foo.bar.baz.bang`, they either all
    // split or none of them do.
    _writer.startRule();

    for (var invocation in invocations) {
      zeroSplit();
      token(invocation.period);
      token(invocation.methodName.token);

      // If a method's argument list includes a block-bodied lambda, we know
      // it will split. Treat the chains before and after that as separate
      // unrelated method chains.
      //
      // This is kind of a hack since it doesn't use the same logic for
      // collection literals, but it makes for much better chains of
      // higher-order method calls.
      var hasLambda = invocation.argumentList.arguments.any(_isBlockLambda);

      // Stop the rule after the last call, but before its arguments. This
      // allows unsplit chains where the last argument list wraps, like:
      //
      //     foo().bar().baz(
      //         argument, list);
      // TODO(rnystrom): Is this what we want?
      if (invocation == invocations.last) {
        _writer.endRule();
        _endNestBodies();

        // For a single method call, stop the span before the arguments to make
        // it easier to keep the call name with the target. In other words,
        // prefer:
        //
        //     target.method(
        //         argument, list);
        //
        // Over:
        //
        //     target
        //         .method(argument, list);
        if (invocations.length == 1) _writer.endSpan();
      } else if (hasLambda) {
        _writer.endRule();
        _endNestBodies();
      }

      visit(invocation.argumentList);

      if (invocation != invocations.last && hasLambda) {
        _startNestBodies();
        _writer.startRule();
      }
    }

    _writer.unnest();

    // For longer method chains, do include the last argument list. We want to
    // make it very easy to split long chains. Wrapping the span around the
    // last args means it won't try to split in the last args to keep the
    // chain together, since that will still split this span.
    if (invocations.length > 1) _writer.endSpan();
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

    // Corner case: put a space between successive "-" operators so we don't
    // inadvertently turn them into a "--" decrement operator.
    if (node.operand is PrefixExpression &&
        (node.operand as PrefixExpression).operator.lexeme == "-") {
      space();
    }

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
    _writeText(node.scriptTag.lexeme.trim(), node.offset);

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
    // Since we output the string literal manually, ensure any preceding
    // comments are written first.
    writePrecedingCommentsAndNewlines(node.literal);

    _writeStringLiteral(node.literal.lexeme, node.offset);
  }

  visitStringInterpolation(StringInterpolation node) {
    // Since we output the interpolated text manually, ensure we include any
    // preceding stuff first.
    writePrecedingCommentsAndNewlines(node.beginToken);

    // Right now, the formatter does not try to do any reformatting of the
    // contents of interpolated strings. Instead, it treats the entire thing as
    // a single (possibly multi-line) chunk of text.
     _writeStringLiteral(
        _source.text.substring(node.beginToken.offset, node.endToken.end),
        node.offset);
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
    soloZeroSplit();
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
    soloSplit(Cost.assignment);
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

    // Use a single rule for all of the variables. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    _writer.startRule();
    visitCommaSeparatedNodes(node.variables, between: split);
    _writer.endRule();
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
    soloZeroSplit();
    visit(node.condition);
    token(node.rightParenthesis);
    if (node.body is! EmptyStatement) space();
    visit(node.body);
    _writer.unnest();
  }

  visitWithClause(WithClause node) {
    soloSplit();
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

  /// Visit the given function [parameters] followed by its [body], printing a
  /// space before it if it's not empty.
  ///
  /// If [afterParameters] is provided, it is invoked between the parameters
  /// and body. (It's used for constructor initialization lists.)
  void _visitBody(FormalParameterList parameters, FunctionBody body,
      [afterParameters()]) {
    if (parameters != null) {
      // If the body is "=>", add an extra level of indentation around the
      // parameters. This ensures that if they wrap, they wrap more deeply than
      // the "=>" does, as in:
      //
      //     someFunction(parameter,
      //             parameter, parameter) =>
      //         "the body";
      if (body is ExpressionFunctionBody) _writer.nestExpression();

      visit(parameters);
      if (afterParameters != null) afterParameters();

      if (body is ExpressionFunctionBody) _writer.unnest();
    }

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

    var first = true;
    for (var node in nodes) {
      if (!first) between();
      first = false;

      visit(node);

      // The comma after the node.
      if (node.endToken.next.lexeme == ",") token(node.endToken.next);
    }
  }

  /// Visits the collection literal [node] whose body starts with [leftBracket],
  /// ends with [rightBracket] and contains [elements].
  void _visitCollectionLiteral(TypedLiteral node, Token leftBracket,
      Iterable<AstNode> elements, Token rightBracket, [int cost]) {
    modifier(node.constKeyword);
    visit(node.typeArguments);

    _startBody(leftBracket, cost: cost, isBody: true);

    // Each list element takes at least 3 characters (one character for the
    // element, one for the comma, one for the space), so force it to split if
    // we know that won't fit.
    // TODO(bob): Is this still needed now that writer preempts?
    if (elements.length > _writer.pageWidth ~/ 3) _writer.forceRules();

    for (var element in elements) {
      if (element != elements.first) _writer.split(nest: false, space: true);

      _writer.nestExpression();

      visit(element);

      // The comma after the element.
      if (element.endToken.next.lexeme == ",") token(element.endToken.next);

      _writer.unnest();
    }

    _endBody(rightBracket, isBody: true);
  }

  /// Visits a list of [combinators] following an "import" or "export"
  /// directive.
  void _visitCombinators(NodeList<Combinator> combinators) {
    if (combinators.isEmpty) return;

    _writer.startRule(new CombinatorRule());
    visitNodes(combinators);
    _writer.endRule();
  }

  /// Visits a [HideCombinator] or [ShowCombinator] starting with [keyword] and
  /// containing [names].
  ///
  /// This assumes it has been called from within the [Rule] created by
  /// [_visitCombinators].
  void _visitCombinator(Token keyword, NodeList<SimpleIdentifier> names) {
    // Allow splitting before the keyword.
    var rule = _writer.rule as CombinatorRule;
    rule.addCombinator(split());

    _writer.nestExpression();
    token(keyword);

    rule.addName(split());
    visitCommaSeparatedNodes(names,
        between: () => rule.addName(split()));

    _writer.unnest();
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

  /// Returns true if [expression] denotes a body.
  ///
  /// Here, "body" means a collection literal or a function expression with a
  /// block body. This is used to tell which arguments to method calls are
  /// bodies or not so we can decide how they should be indented.
  bool _isBody(Expression expression) {
    if (expression is NamedExpression) {
      expression = (expression as NamedExpression).expression;
    }

    // TODO(rnystrom): Should we step into parenthesized expressions?

    // Collections are bodies.
    if (expression is ListLiteral) return true;
    if (expression is MapLiteral) return true;

    // Curly body functions are.
    return _isBlockLambda(expression);
  }

  /// Returns `true` if [expression] is a function expression with a block body.
  bool _isBlockLambda(Expression expression) {
    if (expression is NamedExpression) {
      expression = (expression as NamedExpression).expression;
    }

    if (expression is! FunctionExpression) return false;
    var function = expression as FunctionExpression;
    return function.body is BlockFunctionBody;
  }

  /// Indicates that all bodies visited until the matching [_endNestBodies]
  /// call will be indented based on expression nesting.
  ///
  /// Otherwise, instead of creating an actual body, we just update the
  /// indentation of the current one.
  void _startNestBodies() {
    _nestBodiesCount++;
  }

  /// Ends the nesting caused by a previous call to [_startNestBodies].
  void _endNestBodies() {
    _nestBodiesCount--;
  }

  /// Writes an opening bracket token ("(", "{", "[") and handles indenting and
  /// starting the rule used to split inside the brackets.
  ///
  /// If [space] is `true`, then the initial split will use a space if not
  /// split.  If [isBody] is `true`, creates a new body as well. This is used
  /// for functions and collection literals, but not other "curly bodies" like
  /// classes, blocks, etc.
  void _startBody(Token leftBracket,
      {int cost, bool space: false, bool isBody: false}) {
    token(leftBracket);

    // Indent the body.
    if (isBody && _nestBodiesCount > 0) _writer.startBody();
    _writer.indent();

    // Split after the bracket. Use the explicitly given rule if we have one.
    // Otherwise, create a new rule.
    // TODO(bob): Cost.
    _writer.startRule(_nextBodyRule);
    _nextBodyRule = null;

    _writer.split(nest: false, space: space);
  }

  /// Writes a closing bracket token (")", "}", "]") and handles unindenting
  /// and ending the rule used to split inside the brackets.
  ///
  /// Used for blocks, other curly bodies, and collection literals.
  ///
  /// If [space] is `true`, then the final split will use a space if not split.
  /// if [isBody] is `true`, this closes the innermost body.
  void _endBody(Token rightBracket, {bool space: false, bool isBody: false}) {
    token(rightBracket, before: () {
      // Split before the closing bracket character.
      _writer.unindent();
      _writer.split(nest: false, space: space);
    });

    if (isBody && _nestBodiesCount > 0) _writer.endBody();

    _writer.endRule();
  }

  /// Returns `true` if [node] is immediately contained within an anonymous
  /// [FunctionExpression].
  bool _isInLambda(AstNode node) =>
      node.parent is FunctionExpression &&
      node.parent.parent is! FunctionDeclaration;

  /// Writes the string literal [string] to the output.
  ///
  /// Splits multiline strings into separate chunks so that the line splitter
  /// can handle them correctly.
  void _writeStringLiteral(String string, int offset) {
    // Split each line of a multiline string into separate chunks.
    var lines = string.split(_formatter.lineEnding);

    _writeText(lines.first, offset);
    offset += lines.first.length;

    for (var line in lines.skip(1)) {
      _writer.writeWhitespace(Whitespace.newlineFlushLeft);
      offset++;
      _writeText(line, offset);
      offset += line.length;
    }
  }

  /// Emit the given [modifier] if it's non null, followed by non-breaking
  /// whitespace.
  void modifier(Token modifier) {
    token(modifier, after: space);
  }

  /// Emit a non-breaking space.
  void space() {
    _writer.writeWhitespace(Whitespace.space);
  }

  /// Emit a single mandatory newline.
  void newline() {
    _writer.writeWhitespace(Whitespace.newline);
  }

  /// Emit a two mandatory newlines.
  void twoNewlines() {
    _writer.writeWhitespace(Whitespace.twoNewlines);
  }

  /// Allow either a single space or newline to be emitted before the next
  /// non-whitespace token based on whether a newline exists in the source
  /// between the last token and the next one.
  void spaceOrNewline() {
    _writer.writeWhitespace(Whitespace.spaceOrNewline);
  }

  /// Allow either one or two newlines to be emitted before the next
  /// non-whitespace token based on whether more than one newline exists in the
  /// source between the last token and the next one.
  void oneOrTwoNewlines() {
    _writer.writeWhitespace(Whitespace.oneOrTwoNewlines);
  }

  /// Writes a single space split owned by the current rule.
  ///
  /// Returns the chunk the split was applied to.
  Chunk split() => _writer.split(space: true);

  /// Writes a zero-space split owned by the current rule.
  ///
  /// Returns the chunk the split was applied to.
  Chunk zeroSplit() => _writer.split();

  /// Writes a single space split with its own rule.
  void soloSplit([int cost]) {
    _writer.startRule(new SimpleRule(cost: cost));
    split();
    _writer.endRule();
  }

  /// Writes a zero-space split with its own rule.
  void soloZeroSplit() {
    _writer.startRule();
    _writer.split();
    _writer.endRule();
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

    _writeText(token.lexeme, token.offset);

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

      var sourceComment = new SourceComment(comment.toString().trim(),
          commentLine - previousLine,
          isLineComment: comment.type == TokenType.SINGLE_LINE_COMMENT,
          isStartOfLine: _startColumn(comment) == 1);

      // If this comment contains either of the selection endpoints, mark them
      // in the comment.
      var start = _getSelectionStartWithin(comment.offset, comment.length);
      if (start != null) sourceComment.startSelection(start);

      var end = _getSelectionEndWithin(comment.offset, comment.length);
      if (end != null) sourceComment.endSelection(end);

      comments.add(sourceComment);

      previousLine = _endLine(comment);
      comment = comment.next;
    }

    _writer.writeComments(comments, tokenLine - previousLine, token.lexeme);
  }

  /// Write [text] to the current chunk, given that it starts at [offset] in
  /// the original source.
  ///
  /// Also outputs the selection endpoints if needed.
  void _writeText(String text, int offset) {
    _writer.write(text);

    // If this text contains either of the selection endpoints, mark them in
    // the chunk.
    var start = _getSelectionStartWithin(offset, text.length);
    if (start != null) {
      _writer.startSelectionFromEnd(text.length - start);
    }

    var end = _getSelectionEndWithin(offset, text.length);
    if (end != null) {
      _writer.endSelectionFromEnd(text.length - end);
    }
  }

  /// Returns the number of characters past [offset] in the source where the
  /// selection start appears if it appears before `offset + length`.
  ///
  /// Returns `null` if the selection start has already been processed or is
  /// not within that range.
  int _getSelectionStartWithin(int offset, int length) {
    // If there is no selection, do nothing.
    if (_source.selectionStart == null) return null;

    // If we've already passed it, don't consider it again.
    if (_passedSelectionStart) return null;

    var start = _source.selectionStart - offset;

    // If it started in whitespace before this text, push it forward to the
    // beginning of the non-whitespace text.
    if (start < 0) start = 0;

    // If we haven't reached it yet, don't consider it.
    if (start >= length) return null;

    // We found it.
    _passedSelectionStart = true;

    return start;
  }

  /// Returns the number of characters past [offset] in the source where the
  /// selection endpoint appears if it appears before `offset + length`.
  ///
  /// Returns `null` if the selection endpoint has already been processed or is
  /// not within that range.
  int _getSelectionEndWithin(int offset, int length) {
    // If there is no selection, do nothing.
    if (_source.selectionLength == null) return null;

    // If we've already passed it, don't consider it again.
    if (_passedSelectionEnd) return null;

    var end = _findSelectionEnd() - offset;

    // If it started in whitespace before this text, push it forward to the
    // beginning of the non-whitespace text.
    if (end < 0) end = 0;

    // If we haven't reached it yet, don't consider it.
    if (end > length) return null;

    if (end == length && _findSelectionEnd() == _source.selectionStart) {
      return null;
    }

    // We found it.
    _passedSelectionEnd = true;

    return end;
  }

  /// Calculates the character offset in the source text of the end of the
  /// selection.
  ///
  /// Removes any trailing whitespace from the selection.
  int _findSelectionEnd() {
    if (_selectionEnd != null) return _selectionEnd;

    _selectionEnd = _source.selectionStart + _source.selectionLength;

    // If the selection bumps to the end of the source, pin it there.
    if (_selectionEnd == _source.text.length) return _selectionEnd;

    // Trim off any trailing whitespace. We want the selection to "rubberband"
    // around the selected non-whitespace tokens since the whitespace will
    // be munged by the formatter itself.
    while (_selectionEnd > _source.selectionStart) {
      // Stop if we hit anything other than space, tab, newline or carriage
      // return.
      var char = _source.text.codeUnitAt(_selectionEnd - 1);
      if (char != 0x20 && char != 0x09 && char != 0x0a && char != 0x0d) {
        break;
      }

      _selectionEnd--;
    }

    return _selectionEnd;
  }

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => _lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => _lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      _lineInfo.getLocation(token.offset).columnNumber;
}
