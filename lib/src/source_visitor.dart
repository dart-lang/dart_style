// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// ignore_for_file: avoid_dynamic_calls

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/dart_style/rewrite_cascade.dart';

import 'ast_extensions.dart';
import 'call_chain_visitor.dart';
import 'chunk.dart';
import 'chunk_builder.dart';
import 'constants.dart';
import 'dart_formatter.dart';
import 'rule/argument.dart';
import 'rule/combinator.dart';
import 'rule/initializer.dart';
import 'rule/rule.dart';
import 'rule/type_argument.dart';
import 'source_code.dart';
import 'style_fix.dart';

/// Visits every token of the AST and passes all of the relevant bits to a
/// [ChunkBuilder].
class SourceVisitor extends ThrowingAstVisitor {
  /// The builder for the block that is currently being visited.
  ChunkBuilder builder;

  final DartFormatter _formatter;

  /// Cached line info for calculating blank lines.
  final LineInfo _lineInfo;

  /// The source being formatted.
  final SourceCode _source;

  /// The most recently written token.
  ///
  /// This is used to determine how many lines are between a pair of tokens in
  /// the original source in places where a user can control whether or not a
  /// blank line or newline is left in the output.
  late Token _lastToken;

  /// `true` if the visitor has written past the beginning of the selection in
  /// the original source text.
  bool _passedSelectionStart = false;

  /// `true` if the visitor has written past the end of the selection in the
  /// original source text.
  bool _passedSelectionEnd = false;

  /// The character offset of the end of the selection, if there is a selection.
  ///
  /// This is calculated and cached by [_findSelectionEnd].
  int? _selectionEnd;

  /// How many levels deep inside a constant context the visitor currently is.
  int _constNesting = 0;

  /// Whether we are currently fixing a typedef declaration.
  ///
  /// Set to `true` while traversing the parameters of a typedef being converted
  /// to the new syntax. The new syntax does not allow `int foo()` as a
  /// parameter declaration, so it needs to be converted to `int Function() foo`
  /// as part of the fix.
  bool _insideNewTypedefFix = false;

  /// A stack that tracks forcing nested collections to split.
  ///
  /// Each entry corresponds to a collection currently being visited and the
  /// value is whether or not it should be forced to split. Every time a
  /// collection is entered, it sets all of the existing elements to `true`
  /// then it pushes `false` for itself.
  ///
  /// When done visiting the elements, it removes its value. If it was set to
  /// `true`, we know we visited a nested collection so we force this one to
  /// split.
  final List<bool> _collectionSplits = [];

  /// Associates delimited block expressions with the rule for the containing
  /// expression that manages them.
  ///
  /// This is used for collection literals inside argument lists with block
  /// formatting and spread collection literals inside control flow elements.
  final Map<Token, Rule> _blockCollectionRules = {};

  /// Associates block-bodied function expressions with the rule for the
  /// containing argument list.
  ///
  /// This ensures that we indent the function body and parameter list properly
  /// depending on how the surrounding argument list splits.
  final Map<Token, Rule> _blockFunctionRules = {};

  /// Comments and new lines attached to tokens added here are suppressed
  /// from the output.
  final Set<Token> _suppressPrecedingCommentsAndNewLines = {};

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(this._formatter, this._lineInfo, this._source)
      : builder = ChunkBuilder(_formatter, _source);

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
    writePrecedingCommentsAndNewlines(node.endToken.next!);

    assert(_constNesting == 0, 'Should have exited all const contexts.');

    // Finish writing and return the complete result.
    return builder.end();
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // We generally want to indent adjacent strings because it can be confusing
    // otherwise when they appear in a list of expressions, like:
    //
    //     [
    //       "one",
    //       "two"
    //       "three",
    //       "four"
    //     ]
    //
    // Especially when these stings are longer, it can be hard to tell that
    // "three" is a continuation of the previous argument.
    //
    // However, the indentation is distracting in argument lists that don't
    // suffer from this ambiguity:
    //
    //     test(
    //         "A very long test description..."
    //             "this indentation looks bad.", () { ... });
    //
    // To balance these, we omit the indentation when an adjacent string
    // expression is the only string in an argument list.
    var shouldNest = true;

    var parent = node.parent;
    if (parent is ArgumentList) {
      shouldNest = false;

      for (var argument in parent.arguments) {
        if (argument == node) continue;
        if (argument is StringLiteral) {
          shouldNest = true;
          break;
        }
      }
    } else if (parent is Assertion) {
      // Treat asserts like argument lists.
      shouldNest = false;
      if (parent.condition != node && parent.condition is StringLiteral) {
        shouldNest = true;
      }

      if (parent.message != node && parent.message is StringLiteral) {
        shouldNest = true;
      }
    } else if (parent is VariableDeclaration ||
        parent is AssignmentExpression &&
            parent.rightHandSide == node &&
            parent.parent is ExpressionStatement) {
      // Don't add extra indentation in a variable initializer or assignment:
      //
      //     var variable =
      //         "no extra"
      //         "indent";
      shouldNest = false;
    } else if (parent is NamedExpression || parent is ExpressionFunctionBody) {
      shouldNest = false;
    }

    builder.startSpan();
    builder.startRule();
    if (shouldNest) builder.nestExpression();
    visitNodes(node.strings, between: splitOrNewline);
    if (shouldNest) builder.unnest();
    builder.endRule();
    builder.endSpan();
  }

  @override
  void visitAnnotation(Annotation node) {
    token(node.atSign);
    visit(node.name);

    builder.nestExpression();
    visit(node.typeArguments);
    token(node.period);
    visit(node.constructorName);

    if (node.arguments != null) {
      // Metadata annotations are always const contexts.
      _constNesting++;
      visitArgumentList(node.arguments!);
      _constNesting--;
    }

    builder.unnest();
  }

  // TODO: Update doc.
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
  @override
  void visitArgumentList(ArgumentList node) {
    // Handle empty collections, with or without comments.
    if (node.arguments.isEmpty) {
      _visitBody(node.leftParenthesis, node.arguments, node.rightParenthesis);
      return;
    }

    _visitArgumentList(
        node.leftParenthesis, node.arguments, node.rightParenthesis);
  }

  @override
  void visitAsExpression(AsExpression node) {
    builder.startSpan();
    builder.nestExpression();
    visit(node.expression);
    soloSplit();
    token(node.asOperator);
    space();
    visit(node.type);
    builder.unnest();
    builder.endSpan();
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    _visitAssertion(node);

    // Force the initializer list to split if there are any asserts in it.
    // Since they are statement-like, it looks weird to keep them inline.
    builder.forceRules();
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    _simpleStatement(node, () {
      _visitAssertion(node);
    });
  }

  void _visitAssertion(Assertion node) {
    token(node.assertKeyword);

    var arguments = [node.condition, if (node.message != null) node.message!];

    _visitArgumentList(node.leftParenthesis, arguments, node.rightParenthesis);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    token(node.name);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    builder.nestExpression();

    visit(node.leftHandSide);
    _visitAssignment(node.operator, node.rightHandSide);

    builder.unnest();
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    // If a binary operator sequence appears immediately after a `=>`, don't
    // add an extra level of nesting. Instead, let the subsequent operands line
    // up with the first, as in:
    //
    //     method() =>
    //         argument &&
    //         argument &&
    //         argument;
    var nest = node.parent is! ExpressionFunctionBody;

    _visitBinary<BinaryExpression>(
        node,
        precedence: node.operator.type.precedence,
        nest: nest,
        (expression) => BinaryNode(expression.leftOperand, expression.operator,
            expression.rightOperand));
  }

  @override
  void visitBlock(Block node) {
    // Treat empty blocks specially. In most cases, they are not allowed to
    // split. However, an empty block as the then statement of an if with an
    // else is always split.
    if (node.statements.isEmptyBody(node.rightBracket)) {
      token(node.leftBracket);
      if (_splitEmptyBlock(node)) newline();
      token(node.rightBracket);
      return;
    }

    // If this block is for a function expression in an argument list that
    // shouldn't split the argument list, then don't.
    _visitBody(node.leftBracket, node.statements, node.rightBracket);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    // Space after the parameter list.
    space();

    // The "async" or "sync" keyword.
    token(node.keyword);

    // The "*" in "async*" or "sync*".
    token(node.star);
    if (node.keyword != null) space();

    visit(node.block);
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    token(node.literal);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    _simpleStatement(node, () {
      token(node.breakKeyword);
      visit(node.label, before: space);
    });
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    // Optimized path if we know the cascade will split.
    if (node.cascadeSections.length > 1) {
      _visitSplitCascade(node);
      return;
    }

    // Whether a split in the cascade target expression forces the cascade to
    // move to the next line. It looks weird to move the cascade down if the
    // target expression is a collection, so we don't:
    //
    //     var list = [
    //       stuff
    //     ]
    //       ..add(more);
    var target = node.target;
    var splitIfTargetSplits = true;
    if (node.cascadeSections.length > 1) {
      // Always split if there are multiple cascade sections.
    } else if (target.isCollectionLiteral) {
      splitIfTargetSplits = false;
    } else if (target is InvocationExpression) {
      // If the target is a call with a trailing comma in the argument list,
      // treat it like a collection literal.
      splitIfTargetSplits = !target.argumentList.arguments.hasCommaAfter;
    } else if (target is InstanceCreationExpression) {
      // If the target is a call with a trailing comma in the argument list,
      // treat it like a collection literal.
      splitIfTargetSplits = !target.argumentList.arguments.hasCommaAfter;
    }

    if (splitIfTargetSplits) {
      builder.startLazyRule(node.allowInline ? Rule() : Rule.hard());
    }

    visit(node.target);

    builder.nestExpression(indent: Indent.cascade, now: true);
    builder.startBlockArgumentNesting();

    // If the cascade section shouldn't cause the cascade to split, end the
    // rule early so it isn't affected by it.
    if (!splitIfTargetSplits) {
      builder.startRule(node.allowInline ? Rule() : Rule.hard());
    }

    zeroSplit();

    if (!splitIfTargetSplits) builder.endRule();

    visitNodes(node.cascadeSections, between: zeroSplit);

    if (splitIfTargetSplits) builder.endRule();

    builder.endBlockArgumentNesting();
    builder.unnest();
  }

  /// Format the cascade using a nested block instead of a single inline
  /// expression.
  ///
  /// If the cascade has multiple sections, we know each section will be on its
  /// own line and we know there will be at least one trailing section following
  /// a preceding one. That let's us treat all of the earlier sections as a
  /// separate block like we do with collections and functions, instead of a
  /// monolithic expression. Using a block in turn makes big cascades much
  /// faster to format (like 10x) since the block formatting is memoized and
  /// each cascade section in it is formatted independently.
  ///
  /// The tricky part is that block formatting assumes the entire line will be
  /// part of the block. This is not true of the last section in a cascade,
  /// which may have other trailing code, like the `;` here:
  ///
  ///     var x = someLeadingExpression
  ///       ..firstCascade()
  ///       ..secondCascade()
  ///       ..thirdCascade()
  ///       ..fourthCascade();
  ///
  /// To handle that, we don't put the last section in the block and instead
  /// format it with the surrounding expression. So, from the formatter's
  /// view, the above casade is formatted like:
  ///
  ///     var x = someLeadingExpression
  ///       [ begin block ]
  ///       ..firstCascade()
  ///       ..secondCascade()
  ///       ..thirdCascade()
  ///       [ end block ]
  ///       ..fourthCascade();
  ///
  /// This somewhere between clever and hacky, but it works and allows cascades
  /// of essentially unbounded length to be formatted quickly.
  void _visitSplitCascade(CascadeExpression node) {
    // Rule to split the block.
    builder.startLazyRule(Rule.hard());
    visit(node.target);

    builder.nestExpression(indent: Indent.cascade, now: true);
    builder.startBlockArgumentNesting();

    // If there are comments before the first section, keep them outside of the
    // block. That way code like:
    //
    //     receiver // comment
    //       ..cascade();
    //
    // Keeps the comment on the first line.
    var firstCommentToken = node.cascadeSections.first.beginToken;
    writePrecedingCommentsAndNewlines(firstCommentToken);
    _suppressPrecedingCommentsAndNewLines.add(firstCommentToken);

    // Process the inner cascade sections as a separate block. This way the
    // entire cascade expression isn't line split as a single monolithic unit,
    // which is very slow.
    builder = builder.startBlock(indent: false);

    for (var i = 0; i < node.cascadeSections.length - 1; i++) {
      newline();
      visit(node.cascadeSections[i]);
    }

    // Put comments before the last section inside the block.
    var lastCommentToken = node.cascadeSections.last.beginToken;
    writePrecedingCommentsAndNewlines(lastCommentToken);
    _suppressPrecedingCommentsAndNewLines.add(lastCommentToken);

    builder = builder.endBlock();

    // The last section is outside of the block.
    visit(node.cascadeSections.last);

    builder.endRule();
    builder.endBlockArgumentNesting();
    builder.unnest();
  }

  @override
  void visitCastPattern(CastPattern node) {
    builder.startSpan();
    builder.nestExpression();
    visit(node.pattern);
    soloSplit();
    token(node.asToken);
    space();
    visit(node.type);
    builder.unnest();
    builder.endSpan();
  }

  @override
  void visitCatchClause(CatchClause node) {
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

  @override
  visitCatchClauseParameter(CatchClauseParameter node) {
    token(node.name);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    visitMetadata(node.metadata);

    builder.nestExpression();
    modifier(node.abstractKeyword);
    modifier(node.baseKeyword);
    modifier(node.interfaceKeyword);
    modifier(node.finalKeyword);
    modifier(node.sealedKeyword);
    modifier(node.mixinKeyword);
    modifier(node.inlineKeyword);
    token(node.classKeyword);
    space();
    token(node.name);
    visit(node.typeParameters);
    visit(node.extendsClause);
    _visitClauses(node.withClause, node.implementsClause);
    visit(node.nativeClause, before: space);
    space();

    builder.unnest();
    _visitBody(node.leftBracket, node.members, node.rightBracket);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.abstractKeyword);
      modifier(node.baseKeyword);
      modifier(node.interfaceKeyword);
      modifier(node.finalKeyword);
      modifier(node.sealedKeyword);
      modifier(node.mixinKeyword);
      token(node.typedefKeyword);
      space();
      token(node.name);
      visit(node.typeParameters);
      space();
      token(node.equals);
      space();

      visit(node.superclass);
      _visitClauses(node.withClause, node.implementsClause);
    });
  }

  @override
  void visitComment(Comment node) {}

  @override
  void visitCommentReference(CommentReference node) {}

  @override
  void visitCompilationUnit(CompilationUnit node) {
    visit(node.scriptTag);

    // Put a blank line between the library tag and the other directives.
    Iterable<Directive> directives = node.directives;
    if (directives.isNotEmpty && directives.first is LibraryDirective) {
      visit(directives.first);
      twoNewlines();

      directives = directives.skip(1);
    }

    visitNodes(directives, between: oneOrTwoNewlines);

    var needsDouble = true;
    for (var declaration in node.declarations) {
      var hasBody = declaration is ClassDeclaration ||
          declaration is EnumDeclaration ||
          declaration is ExtensionDeclaration;

      // Add a blank line before types with bodies.
      if (hasBody) needsDouble = true;

      if (needsDouble) {
        twoNewlines();
      } else {
        // Variables and arrow-bodied members can be more tightly packed if
        // the user wants to group things together.
        oneOrTwoNewlines();
      }

      visit(declaration);

      needsDouble = false;
      if (hasBody) {
        // Add a blank line after types declarations with bodies.
        needsDouble = true;
      } else if (declaration is FunctionDeclaration) {
        // Add a blank line after non-empty block functions.
        var body = declaration.functionExpression.body;
        if (body is BlockFunctionBody) {
          needsDouble = body.block.statements.isNotEmpty;
        }
      }
    }
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    // TODO(rnystrom): Consider revisiting whether users prefer this after 2.13.
    /*
    // Flatten else-if style chained conditionals.
    var shouldNest = node.parent is! ConditionalExpression ||
        (node.parent as ConditionalExpression).elseExpression != node;
    if (shouldNest) builder.nestExpression();
    */
    builder.nestExpression();

    // Start lazily so we don't force the operator to split if a line comment
    // appears before the first operand. If we split after one clause in a
    // conditional, always split after both.
    builder.startLazyRule();
    visit(node.condition);

    // Push any block arguments all the way past the leading "?" and ":".
    builder.nestExpression(indent: Indent.block, now: true);
    builder.startBlockArgumentNesting();
    builder.unnest();

    builder.startSpan();

    split();
    token(node.question);
    space();
    builder.nestExpression();
    visit(node.thenExpression);
    builder.unnest();

    split();
    token(node.colon);
    space();
    visit(node.elseExpression);

    // If conditional expressions are directly nested, force them all to split.
    // This line here forces the child, which implicitly forces the surrounding
    // parent rules to split too.
    if (node.parent is ConditionalExpression) builder.forceRules();

    builder.endRule();
    builder.endSpan();
    builder.endBlockArgumentNesting();

    // TODO(rnystrom): Consider revisiting whether users prefer this after 2.13.
    /*
    if (shouldNest) builder.unnest();
    */
    builder.unnest();
  }

  @override
  void visitConfiguration(Configuration node) {
    token(node.ifKeyword);
    space();
    token(node.leftParenthesis);
    visit(node.name);

    if (node.equalToken != null) {
      builder.nestExpression();
      space();
      token(node.equalToken);
      soloSplit();
      visit(node.value);
      builder.unnest();
    }

    token(node.rightParenthesis);
    space();
    visit(node.uri);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    token(node.constKeyword, after: space);
    visit(node.expression);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    visitMetadata(node.metadata);

    modifier(node.externalKeyword);
    modifier(node.constKeyword);
    modifier(node.factoryKeyword);
    visit(node.returnType);
    token(node.period);
    token(node.name);

    // Make the rule for the ":" span both the preceding parameter list and
    // the entire initialization list. This ensures that we split before the
    // ":" if the parameters and initialization list don't all fit on one line.
    if (node.initializers.isNotEmpty) builder.startRule();

    // If the redirecting constructor happens to wrap, we want to make sure
    // the parameter list gets more deeply indented.
    if (node.redirectedConstructor != null) builder.nestExpression();

    _visitFunctionBody(null, node.parameters, node.body, (parameterRule) {
      // Check for redirects or initializer lists.
      if (node.redirectedConstructor != null) {
        _visitConstructorRedirects(node);
        builder.unnest();
      } else if (node.initializers.isNotEmpty) {
        _visitConstructorInitializers(node, parameterRule);

        // End the rule for ":" after all of the initializers.
        builder.endRule();
      }
    });
  }

  void _visitConstructorRedirects(ConstructorDeclaration node) {
    token(node.separator /* = */, before: space);
    soloSplit();
    visitCommaSeparatedNodes(node.initializers);
    visit(node.redirectedConstructor);
  }

  void _visitConstructorInitializers(
      ConstructorDeclaration node, Rule? parameterRule) {
    builder.indent();

    var initializerRule = InitializerRule(parameterRule,
        hasRightDelimiter: node.parameters.rightDelimiter != null);
    builder.startRule(initializerRule);

    // ":".
    initializerRule.bindColon(split());
    token(node.separator);
    space();

    builder.indent();

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);
        split();
      }

      node.initializers[i].accept(this);
    }

    builder.endRule();

    builder.unindent();
    builder.unindent();
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    builder.nestExpression();

    token(node.thisKeyword);
    token(node.period);
    visit(node.fieldName);

    _visitAssignment(node.equals, node.expression);

    builder.unnest();
  }

  @override
  void visitConstructorName(ConstructorName node) {
    visit(node.type);
    token(node.period);
    visit(node.name);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    _simpleStatement(node, () {
      token(node.continueKeyword);
      visit(node.label, before: space);
    });
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    modifier(node.keyword);
    visit(node.type, after: space);
    token(node.name);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    _visitVariablePattern(node.keyword, node.type, node.name);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    visit(node.parameter);
    if (node.separator != null) {
      builder.startSpan();
      builder.nestExpression();

      if (_formatter.fixes.contains(StyleFix.namedDefaultSeparator)) {
        // Change the separator to "=".
        space();
        writePrecedingCommentsAndNewlines(node.separator!);
        _writeText('=', node.separator!);
      } else {
        // The '=' separator is preceded by a space, ":" is not.
        if (node.separator!.type == TokenType.EQ) space();
        token(node.separator);
      }

      soloSplit(Cost.assign);
      visit(node.defaultValue);

      builder.unnest();
      builder.endSpan();
    }
  }

  @override
  void visitDoStatement(DoStatement node) {
    builder.nestExpression();
    token(node.doKeyword);
    space();
    builder.unnest(now: false);
    visit(node.body);

    builder.nestExpression();
    space();
    token(node.whileKeyword);
    space();
    token(node.leftParenthesis);
    soloZeroSplit();
    visit(node.condition);
    token(node.rightParenthesis);
    token(node.semicolon);
    builder.unnest();
  }

  @override
  void visitDottedName(DottedName node) {
    for (var component in node.components) {
      // Write the preceding ".".
      if (component != node.components.first) {
        token(component.beginToken.previous);
      }

      visit(component);
    }
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
    visitMetadata(node.metadata);
    token(node.name);

    var arguments = node.arguments;
    if (arguments != null) {
      builder.nestExpression();
      visit(arguments.typeArguments);

      var constructor = arguments.constructorSelector;
      if (constructor != null) {
        token(constructor.period);
        visit(constructor.name);
      }

      visitArgumentList(arguments.argumentList);
      builder.unnest();
    }
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    visitMetadata(node.metadata);

    builder.nestExpression();
    token(node.enumKeyword);
    space();
    token(node.name);
    visit(node.typeParameters);
    _visitClauses(node.withClause, node.implementsClause);
    space();

    builder.unnest();

    _beginBody(node.leftBracket, space: true);

    visitCommaSeparatedNodes(node.constants, between: splitOrTwoNewlines);

    // If there is a trailing comma, always force the constants to split.
    var trailingComma = node.constants.last.commaAfter;
    if (trailingComma != null) {
      builder.forceRules();
    }

    // The ";" after the constants, which may occur after a trailing comma.
    Token afterConstants = node.constants.last.endToken.next!;
    Token? semicolon;
    if (afterConstants.type == TokenType.SEMICOLON) {
      semicolon = node.constants.last.endToken.next!;
    } else if (trailingComma != null &&
        trailingComma.next!.type == TokenType.SEMICOLON) {
      semicolon = afterConstants.next!;
    }

    if (semicolon != null) {
      // If there is both a trailing comma and a semicolon, move the semicolon
      // to the next line. This doesn't look great but it's less bad than being
      // next to the comma.
      // TODO(rnystrom): If the formatter starts making non-whitespace changes
      // like adding/removing trailing commas, then it should fix this too.
      if (trailingComma != null) newline();

      token(semicolon);

      // Put a blank line between the constants and members.
      if (node.members.isNotEmpty) twoNewlines();
    }

    _visitBodyContents(node.members);

    _endBody(node.rightBracket,
        forceSplit: semicolon != null ||
            trailingComma != null ||
            node.members.isNotEmpty);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    _visitDirectiveMetadata(node);
    _simpleStatement(node, () {
      token(node.exportKeyword);
      space();
      visit(node.uri);

      _visitConfigurations(node.configurations);
      _visitCombinators(node.combinators);
    });
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    // Space after the parameter list.
    space();

    // The "async" or "sync" keyword and "*".
    token(node.keyword);
    token(node.star);
    if (node.keyword != null || node.star != null) space();

    token(node.functionDefinition); // "=>".

    if (node.expression.isDelimitedOrCall) {
      // Don't allow a split between `=>` and a collection. Instead, we want
      // the collection itself to split.
      // TODO: Write tests for this.
      space();
    } else {
      // Split after the "=>".
      builder.nestExpression(now: true);
      builder.startRule(Rule(Cost.arrow));
      split();
    }

    // TODO: See if the logic around binary operators can be simplified.
    // If the body is a binary operator expression, then we want to force the
    // split at `=>` if the operators split. See visitBinaryExpression().
    if (node.expression is! BinaryExpression &&
        !node.expression.isDelimitedOrCall) {
      builder.endRule();
    }

    // If this function invocation appears in an argument list with trailing
    // comma, don't add extra nesting to preserve normal indentation.
    var isArgWithTrailingComma = false;
    var parent = node.parent;
    if (parent is FunctionExpression) {
      isArgWithTrailingComma = parent.isTrailingCommaArgument;
    }

    if (!isArgWithTrailingComma) builder.startBlockArgumentNesting();
    visit(node.expression);
    if (!isArgWithTrailingComma) builder.endBlockArgumentNesting();

    if (!node.expression.isDelimitedOrCall) {
      builder.unnest();
    }

    if (node.expression is BinaryExpression &&
        !node.expression.isDelimitedOrCall) {
      builder.endRule();
    }

    token(node.semicolon);
  }

  /// Parenthesize the target of the given statement's expression (assumed to
  /// be a CascadeExpression) before removing the cascade.
  void _fixCascadeByParenthesizingTarget(ExpressionStatement statement) {
    var cascade = statement.expression as CascadeExpression;
    assert(cascade.cascadeSections.length == 1);

    // Write any leading comments and whitespace immediately, as they should
    // precede the new opening parenthesis, but then prevent them from being
    // written again after the parenthesis.
    writePrecedingCommentsAndNewlines(cascade.target.beginToken);
    _suppressPrecedingCommentsAndNewLines.add(cascade.target.beginToken);

    // Finally, we can revisit a clone of this ExpressionStatement to actually
    // remove the cascade.
    visit(
      fixCascadeByParenthesizingTarget(
        expressionStatement: statement,
        cascadeExpression: cascade,
      ),
    );
  }

  void _removeCascade(ExpressionStatement statement) {
    var cascade = statement.expression as CascadeExpression;
    var subexpression = cascade.cascadeSections.single;
    builder.nestExpression();

    if (subexpression is AssignmentExpression ||
        subexpression is MethodInvocation ||
        subexpression is PropertyAccess) {
      // CascadeExpression("leftHandSide", "..",
      //     AssignmentExpression("target", "=", "rightHandSide"))
      //
      // transforms to
      //
      // AssignmentExpression(
      //     PropertyAccess("leftHandSide", ".", "target"),
      //     "=",
      //     "rightHandSide")
      //
      // CascadeExpression("leftHandSide", "..",
      //     MethodInvocation("target", ".", "methodName", ...))
      //
      // transforms to
      //
      // MethodInvocation(
      //     PropertyAccess("leftHandSide", ".", "target"),
      //     ".",
      //     "methodName", ...)
      //
      // And similarly for PropertyAccess expressions.
      visit(insertCascadeTargetIntoExpression(
          expression: subexpression, cascadeTarget: cascade.target));
    } else {
      throw UnsupportedError(
          '--fix-single-cascade-statements: subexpression of cascade '
          '"$cascade" has unsupported type ${subexpression.runtimeType}.');
    }

    token(statement.semicolon);
    builder.unnest();
  }

  /// Remove any unnecessary single cascade from the given expression statement,
  /// which is assumed to contain a [CascadeExpression].
  ///
  /// Returns true after applying the fix, which involves visiting the nested
  /// expression. Callers must visit the nested expression themselves
  /// if-and-only-if this method returns false.
  bool _fixSingleCascadeStatement(ExpressionStatement statement) {
    var cascade = statement.expression as CascadeExpression;
    if (cascade.cascadeSections.length != 1) return false;

    var target = cascade.target;
    if (target is AsExpression ||
        target is AwaitExpression ||
        target is BinaryExpression ||
        target is ConditionalExpression ||
        target is IsExpression ||
        target is PostfixExpression ||
        target is PrefixExpression) {
      // In these cases, the cascade target needs to be parenthesized before
      // removing the cascade, otherwise the semantics will change.
      _fixCascadeByParenthesizingTarget(statement);
      return true;
    } else if (target is BooleanLiteral ||
        target is FunctionExpression ||
        target is IndexExpression ||
        target is InstanceCreationExpression ||
        target is IntegerLiteral ||
        target is ListLiteral ||
        target is NullLiteral ||
        target is MethodInvocation ||
        target is ParenthesizedExpression ||
        target is PrefixedIdentifier ||
        target is PropertyAccess ||
        target is SimpleIdentifier ||
        target is StringLiteral ||
        target is ThisExpression) {
      // OK to simply remove the cascade.
      _removeCascade(statement);
      return true;
    } else {
      // If we get here, some new syntax was added to the language that the fix
      // does not yet support. Leave it as is.
      return false;
    }
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    if (_formatter.fixes.contains(StyleFix.singleCascadeStatements) &&
        node.expression is CascadeExpression &&
        _fixSingleCascadeStatement(node)) {
      return;
    }

    _simpleStatement(node, () {
      visit(node.expression);
    });
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    // If a type argument in the supertype splits, then split before "extends"
    // too.
    builder.startRule();
    builder.startBlockArgumentNesting();
    split();

    token(node.extendsKeyword);
    space();
    visit(node.superclass);

    builder.endBlockArgumentNesting();
    builder.endRule();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    visitMetadata(node.metadata);

    builder.nestExpression();
    token(node.extensionKeyword);

    // Don't put a space after `extension` if the extension is unnamed. That
    // way, generic unnamed extensions format like `extension<T> on ...`.
    token(node.name, before: space);

    visit(node.typeParameters);

    // If a type argument in the on type splits, then split before "on" too.
    builder.startRule();
    builder.startBlockArgumentNesting();

    split();
    token(node.onKeyword);
    space();
    visit(node.extendedType);

    builder.endBlockArgumentNesting();
    builder.endRule();

    space();
    builder.unnest();
    _visitBody(node.leftBracket, node.members, node.rightBracket);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.externalKeyword);
      modifier(node.staticKeyword);
      modifier(node.abstractKeyword);
      modifier(node.covariantKeyword);
      visit(node.fields);
    });
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      _beginFormalParameter(node);
      token(node.keyword, after: space);
      visit(node.type);
      _separatorBetweenTypeAndVariable(node.type);
      token(node.thisKeyword);
      token(node.period);
      token(node.name);
      visit(node.parameters);
      token(node.question);
      _endFormalParameter(node);
    });
  }

  @override
  Rule? visitFormalParameterList(FormalParameterList node,
      {bool nestExpression = true}) {
    // Corner case: empty parameter lists.
    if (node.parameters.isEmpty) {
      token(node.leftParenthesis);

      // If there is a comment, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      return null;
    }

    var parameterRule = Rule(Cost.parameterList);
    builder.startRule(parameterRule);

    token(node.leftParenthesis);

    // Find the parameter immediately preceding the optional parameters (if
    // there are any).
    FormalParameter? lastRequired;
    for (var i = 0; i < node.parameters.length; i++) {
      if (node.parameters[i] is DefaultFormalParameter) {
        if (i > 0) lastRequired = node.parameters[i - 1];
        break;
      }
    }

    // If all parameters are optional, put the "[" or "{" right after "(".
    if (lastRequired == null) {
      token(node.leftDelimiter);
    }

    // Process the parameters as a separate set of chunks.
    builder = builder.startBlock(
        indentRule: _blockFunctionRules[node.leftParenthesis]);

    var spaceWhenUnsplit = true;
    for (var parameter in node.parameters) {
      builder.split(space: spaceWhenUnsplit);
      visit(parameter);
      writeCommaAfter(parameter);

      // If the optional parameters start after this one, put the delimiter
      // at the end of its line. If we don't split, don't put a space after
      // the delimiter.
      spaceWhenUnsplit = parameter != lastRequired;
      if (parameter == lastRequired) {
        space();
        token(node.leftDelimiter);
        lastRequired = null;
      }
    }

    // Put comments before the closing ")", "]", or "}" inside the block.
    var firstDelimiter = node.rightDelimiter ?? node.rightParenthesis;
    if (firstDelimiter.precedingComments != null) {
      writePrecedingCommentsAndNewlines(firstDelimiter);
    }

    // TODO: Instead of forcing split here, add or remove trailing comma as
    // needed.
    builder = builder.endBlock(forceSplit: node.parameters.hasCommaAfter);
    builder.endRule();

    // Now write the delimiter itself.
    _writeText(firstDelimiter.lexeme, firstDelimiter);
    if (firstDelimiter != node.rightParenthesis) {
      token(node.rightParenthesis);
    }

    return parameterRule;
  }

  @override
  void visitForElement(ForElement node) {
    // Treat a spread of a collection literal like a block in a for statement
    // and don't split after the for parts.
    var isSpreadBody = node.body.isSpreadCollection;

    builder.nestExpression();
    token(node.awaitKeyword, after: space);
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);

    // Start the body rule so that if the parts split, the body does too.
    builder.startRule();

    // The rule for the parts.
    builder.startRule();
    visit(node.forLoopParts);
    token(node.rightParenthesis);
    builder.endRule();
    builder.unnest();

    builder.nestExpression(indent: Indent.block, now: true);

    if (isSpreadBody) {
      space();
    } else {
      split();

      // If the body is a non-spread collection or lambda, indent it.
      builder.startBlockArgumentNesting();
    }

    visit(node.body);

    if (!isSpreadBody) builder.endBlockArgumentNesting();
    builder.unnest();

    // If a control flow element is nested inside another, force the outer one
    // to split.
    if (node.body.isControlFlowElement) builder.forceRules();

    builder.endRule();
  }

  @override
  void visitForStatement(ForStatement node) {
    builder.nestExpression();
    token(node.awaitKeyword, after: space);
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);

    builder.startRule();

    visit(node.forLoopParts);

    token(node.rightParenthesis);
    builder.endRule();
    builder.unnest();

    _visitLoopBody(node.body);
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    // TODO(rnystrom): The formatting logic here is slightly different from
    // how parameter metadata is handled and from how variable metadata is
    // handled. I think what it does works better in the context of a for-in
    // loop, but consider trying to unify this with one of the above.
    //
    // Metadata on class and variable declarations is *always* split:
    //
    //     @foo
    //     class Bar {}
    //
    // Metadata on parameters has some complex logic to handle multiple
    // parameters with metadata. It also indents the parameters farther than
    // the metadata when split:
    //
    //     function(
    //         @foo(long arg list...)
    //             parameter1,
    //         @foo
    //             parameter2) {}
    //
    // For for-in variables, we allow it to not split, like parameters, but
    // don't indent the variable when it does split:
    //
    //     for (
    //         @foo
    //         @bar
    //         var blah in stuff) {}
    // TODO(rnystrom): we used to call builder.startRule() here, but now we call
    // it from visitForStatement2 prior to the `(`.  Is that ok?
    builder.nestExpression();
    builder.startBlockArgumentNesting();

    visitNodes(node.loopVariable.metadata, between: split, after: split);
    visit(node.loopVariable);
    // TODO(rnystrom): we used to call builder.endRule() here, but now we call
    // it from visitForStatement2 after the `)`.  Is that ok?

    _visitForEachPartsFromIn(node);

    builder.endBlockArgumentNesting();
    builder.unnest();
  }

  void _visitForEachPartsFromIn(ForEachParts node) {
    soloSplit();
    token(node.inKeyword);
    space();
    visit(node.iterable);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    visit(node.identifier);
    _visitForEachPartsFromIn(node);
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    builder.startBlockArgumentNesting();
    visitNodes(node.metadata, between: split, after: split);
    token(node.keyword);
    space();
    visit(node.pattern);
    builder.endBlockArgumentNesting();
    _visitForEachPartsFromIn(node);
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    // Nest split variables more so they aren't at the same level
    // as the rest of the loop clauses.
    builder.startBlockArgumentNesting();
    builder.nestExpression();

    // Allow the variables to stay unsplit even if the clauses split.
    builder.startRule();

    var declaration = node.variables;
    visitNodes(declaration.metadata, between: split, after: split);
    modifier(declaration.keyword);
    visit(declaration.type, after: space);

    visitCommaSeparatedNodes(declaration.variables, between: () {
      split();
    });

    builder.endRule();
    builder.endBlockArgumentNesting();
    builder.unnest();

    _visitForPartsFromLeftSeparator(node);
  }

  @override
  void visitForPartsWithExpression(ForPartsWithExpression node) {
    visit(node.initialization);
    _visitForPartsFromLeftSeparator(node);
  }

  @override
  void visitForPartsWithPattern(ForPartsWithPattern node) {
    builder.startBlockArgumentNesting();
    builder.nestExpression();

    var declaration = node.variables;
    visitNodes(declaration.metadata, between: split, after: split);
    token(declaration.keyword);
    space();
    visit(declaration.pattern);
    _visitAssignment(declaration.equals, declaration.expression);

    builder.unnest();
    builder.endBlockArgumentNesting();

    _visitForPartsFromLeftSeparator(node);
  }

  void _visitForPartsFromLeftSeparator(ForParts node) {
    token(node.leftSeparator);

    // The condition clause.
    if (node.condition != null) split();
    visit(node.condition);
    token(node.rightSeparator);

    // The update clause.
    if (node.updaters.isNotEmpty) {
      split();

      // Allow the updates to stay unsplit even if the clauses split.
      builder.startRule();

      visitCommaSeparatedNodes(node.updaters, between: split);

      builder.endRule();
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _visitFunctionOrMethodDeclaration(
      metadata: node.metadata,
      externalKeyword: node.externalKeyword,
      propertyKeyword: node.propertyKeyword,
      modifierKeyword: null,
      operatorKeyword: null,
      name: node.name,
      returnType: node.returnType,
      typeParameters: node.functionExpression.typeParameters,
      formalParameters: node.functionExpression.parameters,
      body: node.functionExpression.body,
    );
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    visit(node.functionDeclaration);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Inside a function body is no longer in the surrounding const context.
    var oldConstNesting = _constNesting;
    _constNesting = 0;

    _visitFunctionBody(node.typeParameters, node.parameters, node.body);

    _constNesting = oldConstNesting;
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    // Try to keep the entire invocation one line.
    builder.startSpan();
    builder.nestExpression();

    visit(node.function);
    visit(node.typeArguments);
    visitArgumentList(node.argumentList);

    builder.unnest();
    builder.endSpan();
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    visit(node.function);
    visit(node.typeArguments);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    visitMetadata(node.metadata);

    if (_formatter.fixes.contains(StyleFix.functionTypedefs)) {
      _simpleStatement(node, () {
        // Inlined visitGenericTypeAlias
        _visitGenericTypeAliasHeader(
            node.typedefKeyword,
            node.name,
            node.typeParameters,
            null,
            node.returnType?.beginToken ?? node.name);

        space();

        // Recursively convert function-arguments to Function syntax.
        _insideNewTypedefFix = true;
        _visitGenericFunctionType(
            node.returnType, null, node.name, null, node.parameters);
        _insideNewTypedefFix = false;
      });
      return;
    }

    _simpleStatement(node, () {
      token(node.typedefKeyword);
      space();
      visit(node.returnType, after: space);
      token(node.name);
      visit(node.typeParameters);
      visit(node.parameters);
    });
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      if (!_insideNewTypedefFix) {
        modifier(node.requiredKeyword);
        modifier(node.covariantKeyword);
        visit(node.returnType, after: space);
        // Try to keep the function's parameters with its name.
        builder.startSpan();
        token(node.name);
        _visitParameterSignature(node.typeParameters, node.parameters);
        token(node.question);
        builder.endSpan();
      } else {
        _beginFormalParameter(node);
        _visitGenericFunctionType(node.returnType, null, node.name,
            node.typeParameters, node.parameters);
        token(node.question);
        split();
        token(node.name);
        _endFormalParameter(node);
      }
    });
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    _visitGenericFunctionType(node.returnType, node.functionKeyword, null,
        node.typeParameters, node.parameters);
    token(node.question);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    visitNodes(node.metadata, between: newline, after: newline);
    _simpleStatement(node, () {
      _visitGenericTypeAliasHeader(node.typedefKeyword, node.name,
          node.typeParameters, node.equals, null);

      space();

      visit(node.type);
    });
  }

  @override
  void visitHideCombinator(HideCombinator node) {
    _visitCombinator(node.keyword, node.hiddenNames);
  }

  @override
  void visitIfElement(IfElement node) {
    // Treat a chain of if-else elements as a single unit so that we don't
    // unnecessarily indent each subsequent section of the chain.
    var ifElements = [
      for (CollectionElement? thisNode = node;
          thisNode is IfElement;
          thisNode = thisNode.elseElement)
        thisNode
    ];

    // If the body of the then or else branch is a spread of a collection
    // literal, then we want to format those collections more like blocks than
    // like standalone objects. In particular, if both the then and else branch
    // are spread collection literals, we want to ensure that they both split
    // if either splits. So this:
    //
    //     [
    //       if (condition) ...[
    //         thenClause
    //       ] else ...[
    //         elseClause
    //       ]
    //     ]
    //
    // And not something like this:
    //
    //     [
    //       if (condition) ...[
    //         thenClause
    //       ] else ...[elseClause]
    //     ]
    //
    // To do that, if we see that either clause is a spread collection, we
    // create a single rule and force both collections to use it.
    var spreadRule = Rule();
    var spreadBrackets = <CollectionElement, Token>{};
    for (var element in ifElements) {
      var spreadBracket = element.thenElement.spreadCollectionBracket;
      if (spreadBracket != null) {
        spreadBrackets[element] = spreadBracket;
        _bindBlockRule(spreadBracket, spreadRule);
      }
    }

    var elseSpreadBracket =
        ifElements.last.elseElement?.spreadCollectionBracket;
    if (elseSpreadBracket != null) {
      spreadBrackets[ifElements.last.elseElement!] = elseSpreadBracket;
      _bindBlockRule(elseSpreadBracket, spreadRule);
    }

    void visitChild(CollectionElement element, CollectionElement child) {
      builder.nestExpression(indent: 2, now: true);

      // Treat a spread of a collection literal like a block in an if statement
      // and don't split after the "else".
      var isSpread = spreadBrackets.containsKey(element);
      if (isSpread) {
        space();
      } else {
        split();

        // If the then clause is a non-spread collection or lambda, make sure the
        // body is indented.
        builder.startBlockArgumentNesting();
      }

      visit(child);

      if (!isSpread) builder.endBlockArgumentNesting();
      builder.unnest();
    }

    // Wrap the whole thing in a single rule. If a split happens inside the
    // condition or the then clause, we want the then and else clauses to split.
    builder.startLazyRule();

    var hasInnerControlFlow = false;
    for (var element in ifElements) {
      _visitIfCondition(element.ifKeyword, element.leftParenthesis,
          element.expression, element.caseClause, element.rightParenthesis);

      visitChild(element, element.thenElement);
      if (element.thenElement.isControlFlowElement) {
        hasInnerControlFlow = true;
      }

      // Handle this element's "else" keyword and prepare to write the element,
      // but don't write it. It will either be the next element in [ifElements]
      // or the final else element handled after the loop.
      if (element.elseElement != null) {
        if (spreadBrackets.containsKey(element)) {
          space();
        } else {
          split();
        }

        token(element.elseKeyword);

        // If there is another if element in the chain, put a space between
        // it and this "else".
        if (element != ifElements.last) space();
      }
    }

    // Handle the final trailing else if there is one.
    var lastElse = ifElements.last.elseElement;
    if (lastElse != null) {
      visitChild(lastElse, lastElse);

      if (lastElse.isControlFlowElement) {
        hasInnerControlFlow = true;
      }
    }

    // If a control flow element is nested inside another, force the outer one
    // to split.
    if (hasInnerControlFlow) builder.forceRules();
    builder.endRule();
  }

  @override
  void visitIfStatement(IfStatement node) {
    _visitIfCondition(node.ifKeyword, node.leftParenthesis, node.expression,
        node.caseClause, node.rightParenthesis);

    void visitClause(Statement clause) {
      if (clause is Block || clause is IfStatement) {
        space();
        visit(clause);
      } else {
        // Allow splitting in a statement-bodied if even though it's against
        // the style guide. Since we can't fix the code itself to follow the
        // style guide, we should at least format it as well as we can.
        builder.indent();
        builder.startRule();

        // If there is an else clause, always split before both the then and
        // else statements.
        if (node.elseStatement != null) {
          builder.writeNewline();
        } else {
          builder.split(nest: false, space: true);
        }

        visit(clause);

        builder.endRule();
        builder.unindent();
      }
    }

    visitClause(node.thenStatement);

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
      visitClause(node.elseStatement!);
    }
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    _visitCombinator(node.implementsKeyword, node.interfaces);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    _visitDirectiveMetadata(node);
    _simpleStatement(node, () {
      token(node.importKeyword);
      space();
      visit(node.uri);

      _visitConfigurations(node.configurations);

      if (node.asKeyword != null) {
        soloSplit();
        token(node.deferredKeyword, after: space);
        token(node.asKeyword);
        space();
        visit(node.prefix);
      }

      _visitCombinators(node.combinators);
    });
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    builder.nestExpression();

    if (node.isCascaded) {
      token(node.period);
    } else {
      visit(node.target);
    }

    finishIndexExpression(node);

    builder.unnest();
  }

  /// Visit the index part of [node], excluding the target.
  ///
  /// Called by [CallChainVisitor] to handle index expressions in the middle of
  /// call chains.
  void finishIndexExpression(IndexExpression node) {
    if (node.target is IndexExpression) {
      // Edge case: On a chain of [] accesses, allow splitting between them.
      // Produces nicer output in cases like:
      //
      //     someJson['property']['property']['property']['property']...
      soloZeroSplit();
    }

    builder.startSpan(Cost.index);
    token(node.question);
    _beginBody(node.leftBracket);
    zeroSplit();
    visit(node.index);
    _endBody(node.rightBracket);
    builder.endSpan();
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    builder.startSpan();

    var includeKeyword = true;

    if (node.keyword != null) {
      if (node.keyword!.keyword == Keyword.NEW &&
          _formatter.fixes.contains(StyleFix.optionalNew)) {
        includeKeyword = false;
      } else if (node.keyword!.keyword == Keyword.CONST &&
          _formatter.fixes.contains(StyleFix.optionalConst) &&
          _constNesting > 0) {
        includeKeyword = false;
      }
    }

    if (includeKeyword) {
      token(node.keyword, after: space);
    } else {
      // Don't lose comments before the discarded keyword, if any.
      writePrecedingCommentsAndNewlines(node.keyword!);
    }

    builder.startSpan(Cost.constructorName);

    // Start the expression nesting for the argument list here, in case this
    // is a generic constructor with type arguments. If it is, we need the type
    // arguments to be nested too so they get indented past the arguments.
    builder.nestExpression();
    visit(node.constructorName);

    _startPossibleConstContext(node.keyword);

    builder.endSpan();
    visitArgumentList(node.argumentList);
    builder.endSpan();

    _endPossibleConstContext(node.keyword);

    builder.unnest();
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    token(node.literal);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    builder.preventSplit();
    token(node.leftBracket);
    builder.startSpan();
    visit(node.expression);
    builder.endSpan();
    token(node.rightBracket);
    builder.endPreventSplit();
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    _writeStringLiteral(node.contents);
  }

  @override
  void visitIsExpression(IsExpression node) {
    builder.startSpan();
    builder.nestExpression();
    visit(node.expression);
    soloSplit();
    token(node.isOperator);
    token(node.notOperator);
    space();
    visit(node.type);
    builder.unnest();
    builder.endSpan();
  }

  @override
  void visitLabel(Label node) {
    visit(node.label);
    token(node.colon);
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    _visitLabels(node.labels);
    visit(node.statement);
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    _visitDirectiveMetadata(node);
    _simpleStatement(node, () {
      token(node.libraryKeyword);
      if (node.name2 != null) {
        visit(node.name2, before: space);
      }
    });
  }

  @override
  void visitLibraryIdentifier(LibraryIdentifier node) {
    visit(node.components.first);
    for (var component in node.components.skip(1)) {
      token(component.beginToken.previous); // "."
      visit(component);
    }
  }

  @override
  void visitListLiteral(ListLiteral node) {
    // Corner case: Splitting inside a list looks bad if there's only one
    // element, so make those more costly.
    var cost = node.elements.length <= 1 ? Cost.singleElementList : Cost.normal;
    _visitCollectionLiteral(node.leftBracket, node.elements, node.rightBracket,
        constKeyword: node.constKeyword,
        typeArguments: node.typeArguments,
        splitOuterCollection: true,
        cost: cost);
  }

  @override
  void visitListPattern(ListPattern node) {
    _visitCollectionLiteral(
      node.leftBracket,
      node.elements,
      node.rightBracket,
      typeArguments: node.typeArguments,
    );
  }

  @override
  void visitLogicalAndPattern(LogicalAndPattern node) {
    _visitBinary<LogicalAndPattern>(
        node,
        (pattern) => BinaryNode(
            pattern.leftOperand, pattern.operator, pattern.rightOperand));
  }

  @override
  void visitLogicalOrPattern(LogicalOrPattern node) {
    _visitBinary<LogicalOrPattern>(
        node,
        (pattern) => BinaryNode(
            pattern.leftOperand, pattern.operator, pattern.rightOperand));
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    builder.nestExpression();
    visit(node.key);
    token(node.separator);
    soloSplit();
    visit(node.value);
    builder.unnest();
  }

  @override
  void visitMapPattern(MapPattern node) {
    _visitCollectionLiteral(node.leftBracket, node.elements, node.rightBracket,
        typeArguments: node.typeArguments);
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    builder.nestExpression();
    visit(node.key);
    token(node.separator);
    soloSplit();
    visit(node.value);
    builder.unnest();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _visitFunctionOrMethodDeclaration(
      metadata: node.metadata,
      externalKeyword: node.externalKeyword,
      propertyKeyword: node.propertyKeyword,
      modifierKeyword: node.modifierKeyword,
      operatorKeyword: node.operatorKeyword,
      name: node.name,
      returnType: node.returnType,
      typeParameters: node.typeParameters,
      formalParameters: node.parameters,
      body: node.body,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // If there's no target, this is a "bare" function call like "foo(1, 2)",
    // or a section in a cascade.
    //
    // If it looks like a constructor or static call, we want to keep the
    // target and method together instead of including the method in the
    // subsequent method chain. When this happens, it's important that this
    // code here has the same rules as in [visitInstanceCreationExpression].
    //
    // That ensures that the way some code is formatted is not affected by the
    // presence or absence of `new`/`const`. In particular, it means that if
    // they run `dart format --fix`, and then run `dart format` *again*, the
    // second run will not produce any additional changes.
    if (node.target == null || node.looksLikeStaticCall) {
      // Try to keep the entire method invocation one line.
      builder.nestExpression();
      builder.startSpan();

      if (node.target != null) {
        builder.startSpan(Cost.constructorName);
        visit(node.target);
        soloZeroSplit();
      }

      // If target is null, this will be `..` for a cascade.
      token(node.operator);
      visit(node.methodName);

      if (node.target != null) builder.endSpan();

      // TODO(rnystrom): Currently, there are no constraints between a generic
      // method's type arguments and arguments. That can lead to some funny
      // splitting like:
      //
      //     method<VeryLongType,
      //             AnotherTypeArgument>(argument,
      //         argument, argument, argument);
      //
      // The indentation is fine, but splitting in the middle of each argument
      // list looks kind of strange. If this ends up happening in real world
      // code, consider putting a constraint between them.
      builder.nestExpression();
      visit(node.typeArguments);
      visitArgumentList(node.argumentList);
      builder.unnest();

      builder.endSpan();
      builder.unnest();
      return;
    }

    CallChainVisitor(this, node).visit();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    visitMetadata(node.metadata);

    builder.nestExpression();
    modifier(node.baseKeyword);
    token(node.mixinKeyword);
    space();
    token(node.name);
    visit(node.typeParameters);

    // If there is only a single superclass constraint, format it like an
    // "extends" in a class.
    var onClause = node.onClause;
    if (onClause != null && onClause.superclassConstraints.length == 1) {
      soloSplit();
      token(onClause.onKeyword);
      space();
      visit(onClause.superclassConstraints.single);
    }

    builder.startRule(CombinatorRule());

    // If there are multiple superclass constraints, format them like the
    // "implements" clause.
    if (onClause != null && onClause.superclassConstraints.length > 1) {
      visit(onClause);
    }

    visit(node.implementsClause);
    builder.endRule();

    space();

    builder.unnest();
    _visitBody(node.leftBracket, node.members, node.rightBracket);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    _visitNamedNode(node.name.label.token, node.name.colon, node.expression);
  }

  @override
  void visitNamedType(NamedType node) {
    var importPrefix = node.importPrefix;
    if (importPrefix != null) {
      builder.startSpan();

      token(importPrefix.name);
      soloZeroSplit();
      token(importPrefix.period);
    }

    token(node.name2);
    visit(node.typeArguments);
    token(node.question);

    if (importPrefix != null) {
      builder.endSpan();
    }
  }

  @override
  void visitNativeClause(NativeClause node) {
    token(node.nativeKeyword);
    visit(node.name, before: space);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    _simpleStatement(node, () {
      builder.nestExpression(now: true);
      soloSplit();
      token(node.nativeKeyword);
      visit(node.stringLiteral, before: space);
      builder.unnest();
    });
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    visit(node.pattern);
    token(node.operator);
  }

  @override
  void visitNullCheckPattern(NullCheckPattern node) {
    visit(node.pattern);
    token(node.operator);
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    token(node.literal);
  }

  @override
  void visitObjectPattern(ObjectPattern node) {
    // Even though object patterns syntactically resemble constructor or
    // function calls, we format them like collections (or like argument lists
    // with trailing commas). In other words, like this:
    //
    //     case Foo(
    //         first: 1,
    //         second: 2,
    //         third: 3
    //       ):
    //       body;
    //
    // Not like:
    //
    //     case Foo(
    //           first: 1,
    //           second: 2,
    //           third: 3):
    //       body;
    //
    // This is less consistent with the corresponding expression form, but is
    // more consistent with all of the other delimited patterns -- list, map,
    // and record -- which have collection-like formatting.
    // TODO(rnystrom): If we move to consistently using collection-like
    // formatting for all argument lists, then this will all be consistent and
    // this comment should be removed.
    visit(node.type);
    _visitCollectionLiteral(
        node.leftParenthesis, node.fields, node.rightParenthesis);
  }

  @override
  void visitOnClause(OnClause node) {
    _visitCombinator(node.onKeyword, node.superclassConstraints);
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    builder.nestExpression();
    token(node.leftParenthesis);
    visit(node.expression);
    builder.unnest();
    token(node.rightParenthesis);
  }

  @override
  void visitParenthesizedPattern(ParenthesizedPattern node) {
    builder.nestExpression();
    token(node.leftParenthesis);
    visit(node.pattern);
    builder.unnest();
    token(node.rightParenthesis);
  }

  @override
  void visitPartDirective(PartDirective node) {
    _visitDirectiveMetadata(node);
    _simpleStatement(node, () {
      token(node.partKeyword);
      space();
      visit(node.uri);
    });
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    _visitDirectiveMetadata(node);
    _simpleStatement(node, () {
      token(node.partKeyword);
      space();
      token(node.ofKeyword);
      space();

      // Part-of may have either a name or a URI. Only one of these will be
      // non-null. We visit both since visit() ignores null.
      visit(node.libraryName);
      visit(node.uri);
    });
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    visit(node.pattern);
    _visitAssignment(node.equals, node.expression);
  }

  @override
  void visitPatternField(PatternField node) {
    var fieldName = node.name;
    if (fieldName != null) {
      var name = fieldName.name;
      if (name != null) {
        _visitNamedNode(fieldName.name!, fieldName.colon, node.pattern);
      } else {
        // Named field with inferred name, like:
        //
        //     var (:x) = (x: 1);
        token(fieldName.colon);
        visit(node.pattern);
      }
    } else {
      visit(node.pattern);
    }
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    visitMetadata(node.metadata);
    builder.nestExpression();
    token(node.keyword);
    space();
    visit(node.pattern);
    _visitAssignment(node.equals, node.expression);
    builder.unnest();
  }

  @override
  void visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    visit(node.declaration);
    token(node.semicolon);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    visit(node.operand);
    token(node.operator);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    CallChainVisitor(this, node).visit();
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    token(node.operator);

    // Edge case: put a space after "-" if the operand is "-" or "--" so we
    // don't merge the operators.
    var operand = node.operand;
    if (operand is PrefixExpression &&
        (operand.operator.lexeme == '-' || operand.operator.lexeme == '--')) {
      space();
    }

    visit(node.operand);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.isCascaded) {
      token(node.operator);
      visit(node.propertyName);
      return;
    }

    CallChainVisitor(this, node).visit();
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    builder.startSpan();

    token(node.thisKeyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    builder.endSpan();
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    modifier(node.constKeyword);
    _visitCollectionLiteral(
        node.leftParenthesis, node.fields, node.rightParenthesis,
        isRecord: true);
  }

  @override
  void visitRecordPattern(RecordPattern node) {
    _visitCollectionLiteral(
        node.leftParenthesis, node.fields, node.rightParenthesis,
        isRecord: true);
  }

  @override
  void visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    var namedFields = node.namedFields;

    // Handle empty record types specially.
    if (node.positionalFields.isEmpty && namedFields == null) {
      token(node.leftParenthesis);

      // If there is a comment inside the parens, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      token(node.question);
      return;
    }

    token(node.leftParenthesis);
    builder.startRule();

    // If all parameters are named, put the "{" right after "(".
    if (node.positionalFields.isEmpty) {
      token(namedFields!.leftBracket);
    }

    // Process the parameters as a separate set of chunks.
    builder = builder.startBlock();

    // Write the positional fields.
    for (var field in node.positionalFields) {
      builder.split(nest: false, space: field != node.positionalFields.first);
      visit(field);
      writeCommaAfter(field);
    }

    // Then the named fields.
    var firstClosingDelimiter = node.rightParenthesis;
    if (namedFields != null) {
      if (node.positionalFields.isNotEmpty) {
        space();
        token(namedFields.leftBracket);
      }

      for (var field in namedFields.fields) {
        builder.split(nest: false, space: field != namedFields.fields.first);
        visit(field);
        writeCommaAfter(field);
      }

      firstClosingDelimiter = namedFields.rightBracket;
    }

    // Put comments before the closing ")" or "}" inside the block.
    if (firstClosingDelimiter.precedingComments != null) {
      newline();
      writePrecedingCommentsAndNewlines(firstClosingDelimiter);
    }

    // If there is a trailing comma, then force the record type to split. But
    // don't force if there is only a single positional element because then
    // the trailing comma is actually mandatory.
    bool force;
    if (namedFields == null) {
      force = node.positionalFields.length > 1 &&
          node.positionalFields.last.hasCommaAfter;
    } else {
      force = namedFields.fields.last.hasCommaAfter;
    }

    builder = builder.endBlock(forceSplit: force);
    builder.endRule();

    // Now write the delimiter(s) themselves.
    _writeText(firstClosingDelimiter.lexeme, firstClosingDelimiter);
    if (namedFields != null) token(node.rightParenthesis);

    token(node.question);
  }

  @override
  void visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    visitParameterMetadata(node.metadata, () {
      visit(node.type);
      token(node.name, before: space);
    });
  }

  @override
  void visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    visitParameterMetadata(node.metadata, () {
      visit(node.type);
      token(node.name, before: space);
    });
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    token(node.operator);
    space();
    visit(node.operand);
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    token(node.rethrowKeyword);
  }

  @override
  void visitRestPatternElement(RestPatternElement node) {
    token(node.operator);
    visit(node.pattern);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    _simpleStatement(node, () {
      token(node.returnKeyword);
      visit(node.expression, before: space);
    });
  }

  @override
  void visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it. Since the script tag must
    // come at the top of the file, we don't have to worry about preceding
    // comments or whitespace.
    _writeText(node.scriptTag.lexeme.trim(), node.scriptTag);
    twoNewlines();
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    _visitCollectionLiteral(node.leftBracket, node.elements, node.rightBracket,
        constKeyword: node.constKeyword,
        typeArguments: node.typeArguments,
        splitOuterCollection: true);
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    _visitCombinator(node.keyword, node.shownNames);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      _beginFormalParameter(node);

      var type = node.type;
      if (_insideNewTypedefFix && type == null) {
        // Parameters can use "var" instead of "dynamic". Since we are inserting
        // "dynamic" in that case, remove the "var".
        if (node.keyword != null) {
          if (node.keyword!.type != Keyword.VAR) {
            modifier(node.keyword);
          } else {
            // Keep any comment attached to "var".
            writePrecedingCommentsAndNewlines(node.keyword!);
          }
        }

        // In function declarations and the old typedef syntax, you can have a
        // parameter name without a type. In the new syntax, you can have a type
        // without a name. Add "dynamic" in that case.

        // Ensure comments on the identifier comes before the inserted type.
        token(node.name, before: () {
          _writeText('dynamic', node.name!);
          split();
        });
      } else {
        modifier(node.keyword);
        // TODO: This was the code on main. I don't think it needs to be merged
        // because _separatorBetweenTypeAndVariable() has similar logic, but
        // leaving here for now so I can investigate the related test failures
        // before I delete it.
        // This was on main instead of the next three lines:
        //         visit(type);
        //         if (node.identifier != null && type != null) {
        //           if (type is GenericFunctionType) {
        //             // Don't split after function types. Instead, keep the variable
        //             // name right after the `)`.
        //             space();
        //           } else {
        //             split();
        //           }
        //         }
        //         visit(node.identifier);

        visit(node.type);
        if (node.name != null) _separatorBetweenTypeAndVariable(node.type);
        token(node.name);
      }

      _endFormalParameter(node);
    });
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _writeStringLiteral(node.literal);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    token(node.spreadOperator);
    visit(node.expression);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    for (var element in node.elements) {
      visit(element);
    }
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    builder.startSpan();

    token(node.superKeyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    builder.endSpan();
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    token(node.superKeyword);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      _beginFormalParameter(node);
      token(node.keyword, after: space);
      visit(node.type, after: split);
      token(node.superKeyword);
      token(node.period);
      token(node.name);
      visit(node.parameters);
      token(node.question);
      _endFormalParameter(node);
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    if (node.cases.isEmptyBody(node.rightBracket)) {
      // Don't allow splitting an empty switch expression.
      _visitSwitchValue(node.switchKeyword, node.leftParenthesis,
          node.expression, node.rightParenthesis);
      token(node.leftBracket);
      token(node.rightBracket);
      return;
    }

    // Start the rule for splitting between the cases before the value. That
    // way, if the value expression splits, the cases do too. Avoids:
    //
    //     switch ([
    //        element,
    //     ]) { inline => caseBody };
    builder.startRule();

    _visitSwitchValue(node.switchKeyword, node.leftParenthesis, node.expression,
        node.rightParenthesis);

    token(node.leftBracket);
    builder = builder.startBlock(space: node.cases.isNotEmpty);

    visitCommaSeparatedNodes(node.cases, between: split);

    var hasTrailingComma =
        node.cases.isNotEmpty && node.cases.last.commaAfter != null;
    _endBody(node.rightBracket, forceSplit: hasTrailingComma);
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    // If the pattern is a series of `||` patterns, then flatten them out and
    // format them like empty cases with fallthrough in a switch statement
    // instead of like a single indented binary pattern. Prefer:
    //
    //   e = switch (obj) {
    //     constant1 ||
    //     constant2 ||
    //     constant3 =>
    //       body
    //   };
    //
    // Instead of:
    //
    //   e = switch (obj) {
    //     constant1 ||
    //        constant2 ||
    //        constant3 =>
    //       body
    //   };
    var orBranches = <DartPattern>[];
    var orTokens = <Token>[];

    void flattenOr(DartPattern e) {
      if (e is! LogicalOrPattern) {
        orBranches.add(e);
      } else {
        flattenOr(e.leftOperand);
        orTokens.add(e.operator);
        flattenOr(e.rightOperand);
      }
    }

    flattenOr(node.guardedPattern.pattern);

    // Wrap the rule for splitting after "=>" around the pattern so that a
    // split in the pattern forces the expression to move to the next line too.
    builder.startLazyRule();

    // Write the "||" operands up to the last one.
    for (var i = 0; i < orBranches.length - 1; i++) {
      // Note that orBranches will always have one more element than orTokens.
      visit(orBranches[i]);
      space();
      token(orTokens[i]);
      split();
    }

    // Wrap the expression's nesting around the final pattern so that a split in
    // the pattern is indented farther then the body expression. Used +2 indent
    // because switch expressions are block-like, similar to how we split the
    // bodies of if and for elements in collections.
    builder.nestExpression(indent: Indent.block);

    var whenClause = node.guardedPattern.whenClause;
    if (whenClause != null) {
      // Wrap the when clause rule around the pattern so that if the pattern
      // splits then we split before "when" too.
      builder.startLazyRule();
      builder.nestExpression(indent: Indent.block);
    }

    // Write the last pattern in the "||" chain. If the case pattern isn't an
    // "||" pattern at all, this writes the one pattern.
    visit(orBranches.last);

    if (whenClause != null) {
      split();
      builder.startBlockArgumentNesting();
      _visitWhenClause(whenClause);
      builder.endBlockArgumentNesting();
      builder.unnest();
      builder.endRule();
    }

    space();
    token(node.arrow);
    split();
    builder.endRule();

    builder.startBlockArgumentNesting();
    visit(node.expression);
    builder.endBlockArgumentNesting();

    builder.unnest();
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _visitSwitchValue(node.switchKeyword, node.leftParenthesis, node.expression,
        node.rightParenthesis);
    _beginBody(node.leftBracket);
    for (var member in node.members) {
      _visitLabels(member.labels);
      token(member.keyword);

      if (member is SwitchCase) {
        space();
        visit(member.expression);
      } else if (member is SwitchPatternCase) {
        space();
        var whenClause = member.guardedPattern.whenClause;
        if (whenClause == null) {
          builder.indent();
          visit(member.guardedPattern.pattern);
          builder.unindent();
        } else {
          // Wrap the when clause rule around the pattern so that if the pattern
          // splits then we split before "when" too.
          builder.startRule();
          builder.nestExpression();
          builder.startBlockArgumentNesting();
          visit(member.guardedPattern.pattern);
          split();
          _visitWhenClause(whenClause);
          builder.endBlockArgumentNesting();
          builder.unnest();
          builder.endRule();
        }
      } else {
        assert(member is SwitchDefault);
        // Nothing to do.
      }

      token(member.colon);

      if (member.statements.isNotEmpty) {
        builder.indent();
        newline();
        visitNodes(member.statements, between: oneOrTwoNewlines);
        builder.unindent();
        oneOrTwoNewlines();
      } else {
        // Don't preserve blank lines between empty cases.
        builder.writeNewline();
      }
    }

    if (node.members.isNotEmpty) {
      newline();
    }
    _endBody(node.rightBracket, forceSplit: node.members.isNotEmpty);
  }

  /// Visits the `switch (expr)` part of a switch statement or expression.
  void _visitSwitchValue(Token switchKeyword, Token leftParenthesis,
      Expression value, Token rightParenthesis) {
    builder.nestExpression();
    token(switchKeyword);
    space();
    token(leftParenthesis);
    soloZeroSplit();
    visit(value);
    token(rightParenthesis);
    space();
    builder.unnest();
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    token(node.poundSign);
    var components = node.components;
    for (var component in components) {
      // The '.' separator
      if (component.previous!.lexeme == '.') {
        token(component.previous);
      }
      token(component);
    }
  }

  @override
  void visitThisExpression(ThisExpression node) {
    token(node.thisKeyword);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    token(node.throwKeyword);
    space();
    visit(node.expression);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.externalKeyword);
      visit(node.variables);
    });
  }

  @override
  void visitTryStatement(TryStatement node) {
    token(node.tryKeyword);
    space();
    visit(node.body);
    visitNodes(node.catchClauses, before: space, between: space);
    token(node.finallyKeyword, before: space, after: space);
    visit(node.finallyBlock);
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    _visitGenericList(node.leftBracket, node.rightBracket, node.arguments);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    visitParameterMetadata(node.metadata, () {
      token(node.name);
      token(node.extendsKeyword, before: space, after: space);
      visit(node.bound);
    });
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    _visitGenericList(node.leftBracket, node.rightBracket, node.typeParameters);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    token(node.name);
    if (node.initializer == null) return;

    // If there are multiple variables being declared, we want to nest the
    // initializers farther so they don't line up with the variables. Bad:
    //
    //     var a =
    //         aValue,
    //         b =
    //         bValue;
    //
    // Good:
    //
    //     var a =
    //             aValue,
    //         b =
    //             bValue;
    var hasMultipleVariables =
        (node.parent as VariableDeclarationList).variables.length > 1;

    _visitAssignment(node.equals!, node.initializer!,
        nest: hasMultipleVariables);
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    visitMetadata(node.metadata);

    // Allow but try to avoid splitting between the type and name.
    builder.startSpan();

    modifier(node.lateKeyword);
    modifier(node.keyword);
    visit(node.type);
    _separatorBetweenTypeAndVariable(node.type, isSolo: true);

    builder.endSpan();

    _startPossibleConstContext(node.keyword);

    // Use a single rule for all of the variables. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    builder.startRule();

    // If there are multiple declarations split across lines, then we want any
    // blocks in the initializers to indent past the variables.
    if (node.variables.length > 1) builder.startBlockArgumentNesting();

    visitCommaSeparatedNodes(node.variables, between: split);

    if (node.variables.length > 1) builder.endBlockArgumentNesting();

    builder.endRule();
    _endPossibleConstContext(node.keyword);
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    _simpleStatement(node, () {
      visit(node.variables);
    });
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    builder.nestExpression();
    token(node.whileKeyword);
    space();
    token(node.leftParenthesis);
    soloZeroSplit();
    visit(node.condition);
    token(node.rightParenthesis);
    builder.unnest();

    _visitLoopBody(node.body);
  }

  @override
  void visitWildcardPattern(WildcardPattern node) {
    _visitVariablePattern(node.keyword, node.type, node.name);
  }

  @override
  void visitWithClause(WithClause node) {
    _visitCombinator(node.withKeyword, node.mixinTypes);
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    _simpleStatement(node, () {
      token(node.yieldKeyword);
      token(node.star);
      space();
      visit(node.expression);
    });
  }

  /// Visit a [node], and if not null, optionally preceded or followed by the
  /// specified functions.
  void visit(AstNode? node, {void Function()? before, void Function()? after}) {
    if (node == null) return;

    if (before != null) before();

    node.accept(this);

    if (after != null) after();
  }

  /// Visit metadata annotations on declarations, and members.
  ///
  /// These always force the annotations to be on the previous line.
  void visitMetadata(NodeList<Annotation> metadata) {
    visitNodes(metadata, between: newline, after: newline);
  }

  /// Visit metadata annotations for a directive.
  ///
  /// Always force the annotations to be on a previous line.
  void _visitDirectiveMetadata(Directive directive) {
    // Preserve a blank line before the first directive since users (in
    // particular the test package) sometimes use that for metadata that
    // applies to the entire library and not the following directive itself.
    var isFirst =
        directive == (directive.parent as CompilationUnit).directives.first;

    visitNodes(directive.metadata,
        between: newline, after: isFirst ? oneOrTwoNewlines : newline);
  }

  /// Visits metadata annotations on parameters and type parameters.
  ///
  /// Unlike other annotations, these are allowed to stay on the same line as
  /// the parameter.
  void visitParameterMetadata(
      NodeList<Annotation> metadata, void Function() visitParameter) {
    if (metadata.isEmpty) {
      visitParameter();
      return;
    }

    // Split before all of the annotations on this parameter or none of them.
    builder.startLazyRule();

    visitNodes(metadata, between: split, after: split);
    visitParameter();

    // Wrap the rule around the parameter too. If it splits, we want to force
    // the annotations to split as well.
    builder.endRule();
  }

  // TODO: Get rid of unused NamedRule parameter.
  /// Visits [node], which may be in an argument list controlled by [rule].
  ///
  /// This is called directly by [ArgumentListVisitorOld] so that it can pass in
  /// the surrounding named argument rule. That way, this can ensure that a
  /// split between the name and argument forces the argument list to split
  /// too.
  void visitNamedArgument(NamedExpression node) {
    _visitNamedNode(node.name.label.token, node.name.colon, node.expression);
  }

  /// Visits syntax of the form `identifier: <node>`: a named argument or a
  /// named record field.
  void _visitNamedNode(Token name, Token colon, AstNode node) {
    builder.nestExpression();
    builder.startSpan();
    token(name);
    token(colon);

    // Don't allow a split between a name and a collection. Instead, we want
    // the collection itself to split, or to split before the argument.
    // TODO: Write tests for named fields in patterns with collection
    // subpatterns.
    if (node.isDelimited) {
      space();
    } else {
      soloSplit();
    }

    visit(node);
    builder.endSpan();
    builder.unnest();
  }

  void _visitArgumentList(Token leftParenthesis, List<Expression> arguments,
      Token rightParenthesis) {
    if (_tryVisitBlockArgumentList(
        leftParenthesis, arguments, rightParenthesis)) {
      return;
    }

    // No argument that needs special block argument handling, so format the
    // argument list like a regular body.
    _beginBody(leftParenthesis);

    for (var argument in arguments) {
      builder.split(nest: false, space: argument != arguments.first);
      visit(argument);
      writeCommaAfter(argument);
    }

    // TODO: Shouldn't look for trailing comma to force split.
    _endBody(rightParenthesis, forceSplit: arguments.hasCommaAfter);
  }

  /// If [arguments] is an argument list with a single argument that should
  /// have block formatting, then formats it using block formatting and returns
  /// `true`. Otherwise returns `false`.
  ///
  /// We allow one collection or block function expression to have block-like
  /// formatting, as in:
  ///
  ///     function([
  ///       element
  ///     ]);
  ///
  /// If there are multiple block-like arguments, then we don't allow any of
  /// them to have this special formatting. This is because Flutter doesn't
  /// seem to do that and because if that's allowed, it's not clear how to
  /// handle the case where some of the block-like arguments need to split and
  /// others don't.
  bool _tryVisitBlockArgumentList(Token leftParenthesis,
      List<Expression> arguments, Token rightParenthesis) {
    Expression? blockArgument;
    Token? blockDelimiter;

    for (var argument in arguments) {
      // Unwrap named arguments.
      var expression = argument;
      if (expression is NamedExpression) {
        expression = expression.expression;
      }

      var (isBlock, delimiter) = switch (expression) {
        FunctionExpression(:BlockFunctionBody body) => (
            true,
            body.block.leftBracket
          ),
        ListLiteral(:var leftBracket) => (true, leftBracket),
        SetOrMapLiteral(:var leftBracket) => (true, leftBracket),
        RecordLiteral(:var leftParenthesis) => (true, leftParenthesis),
        // Allow multi-line strings to have block formatting.
        SimpleStringLiteral(isMultiline: true) => (true, null),
        StringInterpolation(isMultiline: true) => (true, null),
        _ => (false, null)
      };

      if (isBlock) {
        // If we found multiple, then don't give any of them block formatting.
        if (blockArgument != null) return false;

        // We found one.
        blockArgument = argument;
        blockDelimiter = delimiter;
      }
    }

    if (blockArgument == null) return false;

    // If there is a block argument, then we need to handle the argument
    // list and all of its arguments together instead of putting the arguments
    // as children of a BlockChunk for the argument list. That way, we can
    // have a single rule that controls how the argument list and the block
    // argument splits.
    ArgumentListRule rule;
    if (blockArgument is FunctionExpression) {
      rule = FunctionArgumentListRule();

      // Track the argument list rule so that we can indent the function's
      // parameters and body based on whether the argument list splits.
      _blockFunctionRules[blockArgument.parameters!.leftParenthesis] = rule;
      _blockFunctionRules[
          (blockArgument.body as BlockFunctionBody).block.leftBracket] = rule;
    } else if (blockArgument is SimpleStringLiteral ||
        blockArgument is StringInterpolation) {
      rule = FunctionArgumentListRule();
    } else {
      rule = CollectionArgumentListRule();

      // Let the argument list control whether the collection splits.
      _blockCollectionRules[blockDelimiter!] = rule;
    }

    builder.startRule(rule);
    builder.nestExpression(indent: Indent.argumentList);
    builder.startBlockArgumentNesting();
    token(leftParenthesis);

    for (var argument in arguments) {
      // Allow the block argument to split without forcing the argument list
      // to split.
      if (argument == blockArgument) {
        rule.disableSplitOnInnerRules();
      } else {
        rule.enableSplitOnInnerRules();
      }

      builder.split(space: argument != arguments.first);

      // Prefer to split the entire argument list and keep the block argument
      // together. Prefer:
      //
      // ```
      // function(
      //   [element, element, element]
      // );
      // ```
      //
      // Over:
      //
      // ```
      // function([
      //   element,
      //   element,
      //   element
      // ]);
      // ```
      if (argument == blockArgument) builder.startSpan();

      visit(argument);
      writeCommaAfter(argument);

      if (argument == blockArgument) builder.endSpan();
    }

    rule.bindRightParenthesis(zeroSplit());
    token(rightParenthesis);

    builder.endBlockArgumentNesting();
    builder.unnest();
    builder.endRule();
    return true;
  }

  /// Visits the `=` and the following expression in any place where an `=`
  /// appears:
  ///
  /// * Assignment
  /// * Variable declaration
  /// * Constructor initialization
  ///
  /// If [nest] is true, an extra level of expression nesting is added after
  /// the "=".
  void _visitAssignment(Token equalsOperator, Expression rightHandSide,
      {bool nest = false}) {
    space();
    token(equalsOperator);

    if (nest) builder.nestExpression(now: true);

    soloSplit(Cost.assign);

    // Don't wrap the right hand side in a span. This allows initializers that
    // are collections or function calls to split inside the body, like:
    //
    //    variable = function(
    //        argument
    //    );
    //
    // Which is what we want. It also means that other expressions won't try to
    // adhere together, as in:
    //
    //    variable = argument +
    //        argument;
    //
    // Instead of:
    //
    //    variable =
    //        argument + argument;
    //
    // That's OK. We prefer that because it's consistent with the above where
    // the style tries pretty hard to keep something on the same line as the
    // "=".
    visit(rightHandSide);

    if (nest) builder.unnest();
  }

  /// Visits an infix operator-like AST node: a binary operator expression, or
  /// binary pattern.
  ///
  /// In a tree of binary AST nodes, all operators at the same precedence are
  /// treated as a single chain of operators that either all split or none do.
  /// Operands within those (which may themselves be chains of higher
  /// precedence binary operators) are then formatted independently.
  ///
  /// [T] is the type of node being visited and [destructureNode] is a callback
  /// that takes one of those and yields the operands and operator. We need
  /// this since there's no interface shared by the various binary operator
  /// AST nodes.
  ///
  /// If [precedence] is given, then only flattens binary nodes with that same
  /// precedence. If [nest] is `false`, then elides the nesting around the
  /// expression.
  void _visitBinary<T extends AstNode>(
      T node, BinaryNode Function(T node) destructureNode,
      {int? precedence, bool nest = true}) {
    builder.startSpan();

    if (nest) builder.nestExpression();

    // Start lazily so we don't force the operator to split if a line comment
    // appears before the first operand.
    builder.startLazyRule();

    // Blocks as operands to infix operators should always nest like regular
    // operands. (Granted, this case is exceedingly rare in real code.)
    builder.startBlockArgumentNesting();

    void traverse(AstNode e) {
      if (e is! T) {
        visit(e);
      } else {
        var binary = destructureNode(e);
        if (precedence != null &&
            binary.operator.type.precedence != precedence) {
          // Binary node, but a different precedence, so don't flatten.
          visit(e);
        } else {
          traverse(binary.left);

          space();
          token(binary.operator);

          split();
          traverse(binary.right);
        }
      }
    }

    traverse(node);

    builder.endBlockArgumentNesting();

    if (nest) builder.unnest();
    builder.endSpan();
    builder.endRule();
  }

  /// Visits the "with" and "implements" clauses in a type declaration.
  void _visitClauses(
      WithClause? withClause, ImplementsClause? implementsClause) {
    builder.startRule(CombinatorRule());
    visit(withClause);
    visit(implementsClause);
    builder.endRule();
  }

  /// Visits a list of combinators in a directive.
  void _visitCombinators(NodeList<Combinator> combinators) {
    builder.startRule(CombinatorRule());
    visitNodes(combinators);
    builder.endRule();
  }

  /// Visits a type parameter or type argument list.
  void _visitGenericList(
      Token leftBracket, Token rightBracket, List<AstNode> nodes) {
    // TODO: This is simplified from _visitCollectionLiteral. Refactor? Or reuse
    // this code elsewhere?
    _beginBody(leftBracket, rule: Rule(Cost.typeParameterList));

    // Set the block nesting in case an argument is a function type with a
    // trailing comma or a record type.
    builder.startBlockArgumentNesting();

    for (var node in nodes) {
      builder.split(nest: false, space: node != nodes.first);
      visit(node);
      writeCommaAfter(node);
    }

    // If the collection has a trailing comma, the user must want it to split.
    _endBody(rightBracket, forceSplit: nodes.hasCommaAfter);
  }

  /// Visits a sequence of labels before a statement or switch case.
  void _visitLabels(NodeList<Label> labels) {
    visitNodes(labels, between: newline, after: newline);
  }

  /// Visits the members in a type declaration or the statements in a block.
  void _visitBodyContents(List<AstNode> nodes) {
    for (var node in nodes) {
      visit(node);

      // If the node has a non-empty braced body, then require a blank line
      // between it and the next node.
      if (node != nodes.last) {
        if (node.hasNonEmptyBody) {
          twoNewlines();
        } else {
          oneOrTwoNewlines();
        }
      }
    }
  }

  /// Visits a variable or wildcard pattern.
  void _visitVariablePattern(Token? keyword, TypeAnnotation? type, Token name) {
    modifier(keyword);
    visit(type, after: soloSplit);
    token(name);
  }

  /// Visits a top-level function or method declaration.
  void _visitFunctionOrMethodDeclaration({
    required NodeList<Annotation> metadata,
    required Token? externalKeyword,
    required Token? propertyKeyword,
    required Token? modifierKeyword,
    required Token? operatorKeyword,
    required Token name,
    required TypeAnnotation? returnType,
    required TypeParameterList? typeParameters,
    required FormalParameterList? formalParameters,
    required FunctionBody body,
  }) {
    visitMetadata(metadata);

    builder.startSpan();
    modifier(externalKeyword);
    modifier(modifierKeyword);
    visit(returnType, after: soloSplit);
    modifier(propertyKeyword);
    modifier(operatorKeyword);
    token(name);
    builder.endSpan();

    _visitFunctionBody(typeParameters, formalParameters, body);
  }

  /// Visit the given function [parameters] followed by its [body], printing a
  /// space before it if it's not empty.
  ///
  /// If [beforeBody] is provided, it is invoked before the body is visited.
  void _visitFunctionBody(TypeParameterList? typeParameters,
      FormalParameterList? parameters, FunctionBody body,
      [void Function(Rule? parameterRule)? beforeBody]) {
    var parameterRule = _visitParameterSignature(typeParameters, parameters);

    if (beforeBody != null) beforeBody(parameterRule);
    visit(body);
  }

  /// Visits the type parameters (if any) and formal parameters of a method
  /// declaration, function declaration, or generic function type.
  ///
  /// If a rule was created for the parameters, returns it.
  Rule? _visitParameterSignature(
      TypeParameterList? typeParameters, FormalParameterList? parameters) {
    // Start the nesting for the parameters here, so they indent past the
    // type parameters too, if any.
    builder.nestExpression();

    visit(typeParameters);

    Rule? rule;
    if (parameters != null) {
      rule = visitFormalParameterList(parameters, nestExpression: false);
    }

    builder.unnest();

    return rule;
  }

  /// Visits the body statement of a `for`, `for in`, or `while` loop.
  void _visitLoopBody(Statement body) {
    if (body is EmptyStatement) {
      // No space before the ";".
      visit(body);
    } else if (body is Block) {
      space();
      visit(body);
    } else {
      // Allow splitting in a statement-bodied loop even though it's against
      // the style guide. Since we can't fix the code itself to follow the
      // style guide, we should at least format it as well as we can.
      builder.indent();
      builder.startRule();

      builder.split(nest: false, space: true);
      visit(body);

      builder.endRule();
      builder.unindent();
    }
  }

  /// Visit a list of [nodes] if not null, optionally separated and/or preceded
  /// and followed by the given functions.
  void visitNodes(Iterable<AstNode> nodes,
      {void Function()? before,
      void Function()? between,
      void Function()? after}) {
    if (nodes.isEmpty) return;

    if (before != null) before();

    visit(nodes.first);
    for (var node in nodes.skip(1)) {
      if (between != null) between();
      visit(node);
    }

    if (after != null) after();
  }

  /// Visit a comma-separated list of [nodes] if not null.
  void visitCommaSeparatedNodes(Iterable<AstNode> nodes,
      {void Function()? between}) {
    if (nodes.isEmpty) return;

    between ??= space;

    var first = true;
    for (var node in nodes) {
      if (!first) between();
      first = false;

      visit(node);

      // The comma after the node.
      if (node.endToken.next!.lexeme == ',') token(node.endToken.next);
    }
  }

  /// Visits the construct whose body starts with [leftBracket],
  /// ends with [rightBracket] and contains [elements].
  ///
  /// This is used for collection literals, collection patterns, and argument
  /// lists with a trailing comma which are considered "collection-like".
  ///
  /// If [splitOuterCollection] is `true` then this collection forces any
  /// surrounding collections to split even if this one doesn't. We do this for
  /// collection literals, but not other collection-like constructs.
  void _visitCollectionLiteral(
      Token leftBracket, List<AstNode> elements, Token rightBracket,
      {Token? constKeyword,
      TypeArgumentList? typeArguments,
      int? cost,
      bool splitOuterCollection = false,
      bool isRecord = false,
      bool useLineCommentsToFormat = true}) {
    // See if `const` should be removed.
    if (constKeyword != null &&
        _constNesting > 0 &&
        _formatter.fixes.contains(StyleFix.optionalConst)) {
      // Don't lose comments before the discarded keyword, if any.
      writePrecedingCommentsAndNewlines(constKeyword);
    } else {
      modifier(constKeyword);
    }

    visit(typeArguments);

    // Handle empty collections, with or without comments.
    if (elements.isEmpty) {
      _visitBody(leftBracket, elements, rightBracket);
      return;
    }

    // Unlike other collections, records don't force outer ones to split.
    if (splitOuterCollection) {
      // Force all of the surrounding collections to split.
      _collectionSplits.fillRange(0, _collectionSplits.length, true);

      // Add this collection to the stack.
      _collectionSplits.add(false);
    }

    // In cases where a collection could have block-like formatting in an
    // argument list, prefer to split at the argument list and keep the
    // collection together.
    builder.startSpan();

    var blockRule = _blockCollectionRules[leftBracket];
    _beginBody(leftBracket, rule: blockRule);
    _startPossibleConstContext(constKeyword);

    // If a collection contains a line comment, we assume it's a big complex
    // blob of data with some documented structure. In that case, the user
    // probably broke the elements into lines deliberately, so preserve those.
    if (useLineCommentsToFormat &&
        _containsLineComments(elements, rightBracket)) {
      // TODO: Should this keeping using TypeArgumentRule or can it be
      // simplified?
      // Newlines are significant, so we'll explicitly write those. Elements
      // on the same line all share an argument-list-like rule that allows
      // splitting between zero, one, or all of them. This is faster in long
      // lists than using individual splits after each element.
      var lineRule = TypeArgumentRule();
      builder.startLazyRule(lineRule);

      for (var element in elements) {
        // See if the next element is on the next line.
        if (_endLine(element.beginToken.previous!) !=
            _startLine(element.beginToken)) {
          oneOrTwoNewlines();

          // Start a new rule for the new line.
          builder.endRule();
          lineRule = TypeArgumentRule();
          builder.startLazyRule(lineRule);
        } else {
          lineRule.beforeArgument(split());
        }

        visit(element);
        writeCommaAfter(element);
      }

      builder.endRule();
    } else {
      for (var element in elements) {
        builder.split(nest: false, space: element != elements.first);
        visit(element);
        writeCommaAfter(element);
      }
    }

    // If there is a collection inside this one, it forces this one to split.
    var force = false;
    if (splitOuterCollection) {
      force = _collectionSplits.removeLast();
    }

    // If the collection has a trailing comma, the user must want it to split.
    // (Unless it's a single-element record literal, in which case the trailing
    // comma is required for disambiguation.)
    var isSingleElementRecord = isRecord && elements.length == 1;
    if (elements.hasCommaAfter && !isSingleElementRecord) force = true;

    _endPossibleConstContext(constKeyword);
    var blockChunk = _endBody(rightBracket, forceSplit: force);

    if (blockRule is CollectionArgumentListRule) {
      // This collection is a block argument, so let argument list rule know its
      // chunk.
      blockRule.bindBlock(blockChunk);
    }
  }

  /// Begins writing a formal parameter of any kind.
  void _beginFormalParameter(FormalParameter node) {
    builder.startLazyRule(Rule(Cost.typeAnnotation));
    builder.nestExpression();
    modifier(node.requiredKeyword);
    modifier(node.covariantKeyword);
  }

  /// Ends writing a formal parameter of any kind.
  void _endFormalParameter(FormalParameter node) {
    builder.unnest();
    builder.endRule();
  }

  /// Writes a `Function` function type.
  ///
  /// Used also by a fix, so there may not be a [functionKeyword].
  /// In that case [functionKeywordPosition] should be the source position
  /// used for the inserted "Function" text.
  void _visitGenericFunctionType(
      AstNode? returnType,
      Token? functionKeyword,
      Token? positionToken,
      TypeParameterList? typeParameters,
      FormalParameterList parameters) {
    builder.startLazyRule(Rule(Cost.typeAnnotation));
    builder.nestExpression();

    visit(returnType, after: split);
    if (functionKeyword != null) {
      token(functionKeyword);
    } else {
      _writeText('Function', positionToken!);
    }

    builder.unnest();
    builder.endRule();
    _visitParameterSignature(typeParameters, parameters);
  }

  /// Writes the header of a new-style typedef.
  ///
  /// Also used by a fix so there may not be an [equals] token.
  /// If [equals] is `null`, then [equalsPosition] must be a
  /// position to use for the inserted text "=".
  void _visitGenericTypeAliasHeader(Token typedefKeyword, Token name,
      AstNode? typeParameters, Token? equals, Token? positionToken) {
    token(typedefKeyword);
    space();
    token(name);
    visit(typeParameters);
    space();

    if (equals != null) {
      token(equals);
    } else {
      _writeText('=', positionToken!);
    }
  }

  /// Visits the `if (<expr> [case <pattern> [when <expr>]])` header of an if
  /// statement or element.
  void _visitIfCondition(Token ifKeyword, Token leftParenthesis,
      AstNode condition, CaseClause? caseClause, Token rightParenthesis) {
    builder.nestExpression();
    token(ifKeyword);
    space();
    token(leftParenthesis);

    if (caseClause == null) {
      // Simple if with no "case".
      visit(condition);
    } else {
      // If-case.

      // Wrap the rule for splitting before "case" around the value expression
      // so that if the value splits, we split before "case" too.
      var caseRule = Rule();
      builder.startRule(caseRule);

      visit(condition);

      // "case" and pattern.
      split();
      token(caseClause.caseKeyword);
      space();
      builder.startBlockArgumentNesting();
      builder.nestExpression(now: true);
      visit(caseClause.guardedPattern.pattern);
      builder.unnest();
      builder.endBlockArgumentNesting();

      builder.endRule(); // Case rule.

      var whenClause = caseClause.guardedPattern.whenClause;
      if (whenClause != null) {
        // Wrap the rule for "when" around the guard so that a split in the
        // guard splits at "when" too.
        builder.startRule();
        split();
        builder.startBlockArgumentNesting();
        builder.nestExpression();
        _visitWhenClause(whenClause);
        builder.unnest();
        builder.endBlockArgumentNesting();
        builder.endRule(); // Guard rule.
      }
    }

    token(rightParenthesis);
    builder.unnest();
  }

  void _visitWhenClause(WhenClause whenClause) {
    token(whenClause.whenKeyword);
    space();
    visit(whenClause.expression);
  }

  /// Writes the separator between a type annotation and a variable or
  /// parameter. If the preceding type annotation ends in a delimited list of
  /// elements that have block formatting, then we don't split between the
  /// type annotation and parameter name, as in:
  ///
  ///     Function(
  ///       int,
  ///     ) variable;
  ///
  /// Otherwise, we can.
  void _separatorBetweenTypeAndVariable(TypeAnnotation? type,
      {bool isSolo = false}) {
    if (type == null) return;

    if (type is GenericFunctionType || type is RecordTypeAnnotation) {
      space();
    } else if (isSolo) {
      soloSplit();
    } else {
      split();
    }
  }

  /// Whether [node] should be forced to split even if completely empty.
  ///
  /// Most empty blocks format as `{}` but in a couple of cases where there is
  /// a subsequent block, we split the previous one.
  bool _splitEmptyBlock(Block node) {
    // Force a split when used as the then body of an if with an else:
    //
    //     if (condition) {
    //     } else ...
    if (node.parent is IfStatement) {
      var ifStatement = node.parent as IfStatement;
      return ifStatement.elseStatement != null &&
          ifStatement.thenStatement == node;
    }

    // Force a split in an empty catch if there is a finally or other catch
    // after it:
    if (node.parent is CatchClause && node.parent!.parent is TryStatement) {
      var tryStatement = node.parent!.parent as TryStatement;

      // Split the catch if there is something after it, a finally or another
      // catch.
      return tryStatement.finallyBlock != null ||
          node != tryStatement.catchClauses.last.body;
    }

    return false;
  }

  /// Returns `true` if the collection withs [elements] delimited by
  /// [rightBracket] contains any line comments.
  ///
  /// This only looks for comments at the element boundary. Comments within an
  /// element are ignored.
  bool _containsLineComments(Iterable<AstNode> elements, Token rightBracket) {
    bool hasLineCommentBefore(Token token) {
      Token? comment = token.precedingComments;
      for (; comment != null; comment = comment.next) {
        if (comment.type == TokenType.SINGLE_LINE_COMMENT) return true;
      }

      return false;
    }

    // Look before each element.
    for (var element in elements) {
      if (hasLineCommentBefore(element.beginToken)) return true;
    }

    // Look before the closing bracket.
    return hasLineCommentBefore(rightBracket);
  }

  /// Begins writing a bracket-delimited body whose contents are a nested
  /// block chunk.
  ///
  /// If [space] is `true`, writes a space after [leftBracket] when not split.
  ///
  /// Writes the delimiter (with a space after it when unsplit if [space] is
  /// `true`).
  void _beginBody(Token leftBracket, {Rule? rule, bool space = false}) {
    token(leftBracket);

    // Create a rule for whether or not to split the block contents. If this
    // literal is associated with an argument list or if element that wants to
    // handle splitting and indenting it, use its rule. Otherwise, use a
    // default rule.
    builder.startRule(rule ?? _blockCollectionRules[leftBracket]);

    // Process the contents as a separate set of chunks.
    builder = builder.startBlock(
        indentRule: _blockFunctionRules[leftBracket], space: space);
  }

  /// Ends the body started by a call to [_beginBody()].
  ///
  /// If [space] is `true`, writes a space before the closing bracket when not
  /// split. If [forceSplit] is `true`, forces the body to split.
  Chunk _endBody(Token rightBracket, {bool forceSplit = false}) {
    // Put comments before the closing delimiter inside the block.
    var hasLeadingNewline = writePrecedingCommentsAndNewlines(rightBracket);

    builder = builder.endBlock(forceSplit: hasLeadingNewline || forceSplit);

    builder.endRule();

    // Now write the delimiter itself.
    return _writeText(rightBracket.lexeme, rightBracket);
  }

  /// Visits a list of configurations in an import or export directive.
  void _visitConfigurations(NodeList<Configuration> configurations) {
    if (configurations.isEmpty) return;

    builder.startRule();

    for (var configuration in configurations) {
      split();
      visit(configuration);
    }

    builder.endRule();
  }

  /// Visits a "combinator".
  ///
  /// This is a [keyword] followed by a list of [nodes], with specific line
  /// splitting rules. As the name implies, this is used for [HideCombinator]
  /// and [ShowCombinator], but it also used for "with" and "implements"
  /// clauses in class declarations, which are formatted the same way.
  ///
  /// This assumes the current rule is a [CombinatorRule].
  void _visitCombinator(Token keyword, Iterable<AstNode> nodes) {
    // Allow splitting before the keyword.
    var rule = builder.rule as CombinatorRule;
    rule.addCombinator(split());

    builder.nestExpression();
    builder.startBlockArgumentNesting();

    token(keyword);

    rule.addName(split());
    visitCommaSeparatedNodes(nodes, between: () => rule.addName(split()));

    builder.endBlockArgumentNesting();
    builder.unnest();
  }

  /// If [keyword] is `const`, begins a new constant context.
  void _startPossibleConstContext(Token? keyword) {
    if (keyword != null && keyword.keyword == Keyword.CONST) {
      _constNesting++;
    }
  }

  /// If [keyword] is `const`, ends the current outermost constant context.
  void _endPossibleConstContext(Token? keyword) {
    if (keyword != null && keyword.keyword == Keyword.CONST) {
      _constNesting--;
    }
  }

  /// Writes the simple statement or semicolon-delimited top-level declaration.
  ///
  /// Handles nesting if a line break occurs in the statement and writes the
  /// terminating semicolon. Invokes [body] which should write statement itself.
  void _simpleStatement(AstNode node, void Function() body) {
    builder.nestExpression();
    body();

    // TODO(rnystrom): Can the analyzer move "semicolon" to some shared base
    // type?
    token((node as dynamic).semicolon);
    builder.unnest();
  }

  /// Marks the block that starts with [token] as being controlled by
  /// [rule].
  ///
  /// When the block is visited, these will determine the indentation and
  /// splitting rule for the block. These are used for handling block-like
  /// expressions inside argument lists and spread collections inside if
  /// elements.
  void _bindBlockRule(Token token, Rule rule) {
    _blockCollectionRules[token] = rule;
  }

  /// Writes the brace-delimited body containing [nodes].
  void _visitBody(Token leftBracket, List<AstNode> nodes, Token rightBracket) {
    // Don't allow splitting in an empty body.
    if (nodes.isEmptyBody(rightBracket)) {
      token(leftBracket);
      token(rightBracket);
      return;
    }

    _beginBody(leftBracket);
    _visitBodyContents(nodes);
    _endBody(rightBracket, forceSplit: nodes.isNotEmpty);
  }

  /// Writes the string literal [string] to the output.
  ///
  /// Splits multiline strings into separate chunks so that the line splitter
  /// can handle them correctly.
  void _writeStringLiteral(Token string) {
    // Since we output the string literal manually, ensure any preceding
    // comments are written first.
    writePrecedingCommentsAndNewlines(string);

    // Split each line of a multiline string into separate chunks.
    var lines = string.lexeme.split(_formatter.lineEnding!);
    var offset = string.offset;

    _writeText(lines.first, string, offset: offset);
    offset += lines.first.length;

    for (var line in lines.skip(1)) {
      builder.writeNewline(flushLeft: true, nest: true);
      offset++;
      _writeText(line, string, offset: offset, mergeEmptySplits: false);
      offset += line.length;
    }
  }

  /// Write the comma token following [node], if there is one.
  void writeCommaAfter(AstNode node) {
    token(node.commaAfter);
  }

  /// Emit the given [modifier] if it's non null, followed by non-breaking
  /// whitespace.
  void modifier(Token? modifier) {
    token(modifier, after: space);
  }

  /// Emit a non-breaking space.
  void space() {
    builder.writeSpace();
  }

  /// Emit a single mandatory newline.
  void newline() {
    builder.writeNewline();
  }

  /// Emit a two mandatory newlines.
  void twoNewlines() {
    builder.writeNewline(isDouble: true);
  }

  /// Allow either a single split or newline to be emitted before the next
  /// non-whitespace token based on whether a newline exists in the source
  /// between the last token and the next one.
  void splitOrNewline() {
    if (_linesBeforeNextToken > 0) {
      builder.writeNewline(nest: true);
    } else {
      split();
    }
  }

  /// Allow either a single split or newline to be emitted before the next
  /// non-whitespace token based on whether any blank lines exist in the source
  /// between the last token and the next one.
  void splitOrTwoNewlines() {
    if (_linesBeforeNextToken > 1) {
      twoNewlines();
    } else {
      split();
    }
  }

  /// Allow either one or two newlines to be emitted before the next
  /// non-whitespace token based on whether any blank lines exist in the source
  /// between the last token and the next one.
  void oneOrTwoNewlines() {
    builder.writeNewline(isDouble: _linesBeforeNextToken > 1);
  }

  /// The number of newlines between the last written token and the next one to
  /// be written, including comments.
  ///
  /// Zero means "on the same line", one means "on subsequent lines", etc.
  int get _linesBeforeNextToken {
    var previous = _lastToken;
    var next = previous.next!;
    if (next.precedingComments != null) {
      next = next.precedingComments!;
    }

    return _startLine(next) - _endLine(previous);
  }

  /// Writes a single space split owned by the current rule.
  ///
  /// Returns the chunk the split was applied to.
  Chunk split() => builder.split(space: true);

  /// Writes a zero-space split owned by the current rule.
  ///
  /// Returns the chunk the split was applied to.
  Chunk zeroSplit() => builder.split();

  /// Writes a single space split with its own rule.
  Rule soloSplit([int cost = Cost.normal]) {
    var rule = Rule(cost);
    builder.startRule(rule);
    split();
    builder.endRule();
    return rule;
  }

  /// Writes a zero-space split with its own rule.
  void soloZeroSplit() {
    builder.startRule();
    builder.split();
    builder.endRule();
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// Does nothing if [token] is `null`. If [before] is given, it will be
  /// executed before the token is outout. Likewise, [after] will be called
  /// after the token is output.
  void token(Token? token, {void Function()? before, void Function()? after}) {
    if (token == null) return;

    writePrecedingCommentsAndNewlines(token);

    if (before != null) before();

    _writeText(token.lexeme, token);

    if (after != null) after();
  }

  /// Writes all formatted whitespace and comments that appear before [token].
  bool writePrecedingCommentsAndNewlines(Token token) {
    Token? comment = token.precedingComments;

    // For performance, avoid calculating newlines between tokens unless
    // actually needed.
    if (comment == null) return false;

    // If the token's comments are being moved by a fix, do not write them here.
    if (_suppressPrecedingCommentsAndNewLines.contains(token)) return false;

    var previousLine = _endLine(token.previous!);
    var tokenLine = _startLine(token);

    // Edge case: The analyzer includes the "\n" in the script tag's lexeme,
    // which confuses some of these calculations. We don't want to allow a
    // blank line between the script tag and a following comment anyway, so
    // just override the script tag's line.
    if (token.previous!.type == TokenType.SCRIPT_TAG) previousLine = tokenLine;

    var comments = <SourceComment>[];
    while (comment != null) {
      var commentLine = _startLine(comment);

      // Don't preserve newlines at the top of the file.
      if (comment == token.precedingComments &&
          token.previous!.type == TokenType.EOF) {
        previousLine = commentLine;
      }

      var text = comment.lexeme.trim();
      var linesBefore = commentLine - previousLine;
      var flushLeft = _startColumn(comment) == 1;

      if (text.startsWith('///') && !text.startsWith('////')) {
        // Line doc comments are always indented even if they were flush left.
        flushLeft = false;

        // Always add a blank line (if possible) before a doc comment block.
        if (comment == token.precedingComments) linesBefore = 2;
      }

      var type = CommentType.block;
      if (text.startsWith('///') && !text.startsWith('////') ||
          text.startsWith('/**') && text != '/**/') {
        // TODO(rnystrom): Check that the comment isn't '/**/' because some of
        // the dart_style tests use that to mean inline block comments. While
        // refactoring the Chunk representation to move splits to the front of
        // Chunk, I want to preserve the current test behavior. The fact that
        // those tests pass with the old representation is a buggy quirk of the
        // comment handling.
        type = CommentType.doc;
      } else if (comment.type == TokenType.SINGLE_LINE_COMMENT) {
        type = CommentType.line;
      } else if (commentLine == previousLine || commentLine == tokenLine) {
        type = CommentType.inlineBlock;
      }

      var sourceComment =
          SourceComment(text, type, linesBefore, flushLeft: flushLeft);

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

    builder.writeComments(comments, tokenLine - previousLine, token.lexeme);

    // TODO(rnystrom): This is wrong. Consider:
    //
    // [/* inline comment */
    //     // line comment
    //     element];
    return comments.first.linesBefore > 0;
  }

  /// Write [text] to the current chunk, derived from [token].
  ///
  /// Also outputs the selection endpoints if needed.
  ///
  /// Usually, [text] is simply [token]'s lexeme, but for fixes, multi-line
  /// strings, or a couple of other cases, it will be different.
  ///
  /// If [offset] is given, uses that for calculating selection location.
  /// Otherwise, uses the offset of [token].
  Chunk _writeText(String text, Token token,
      {int? offset, bool mergeEmptySplits = true}) {
    offset ??= token.offset;

    var chunk = builder.write(text, mergeEmptySplits: mergeEmptySplits);

    // If this text contains either of the selection endpoints, mark them in
    // the chunk.
    var start = _getSelectionStartWithin(offset, text.length);
    if (start != null) {
      builder.startSelectionFromEnd(text.length - start);
    }

    var end = _getSelectionEndWithin(offset, text.length);
    if (end != null) {
      builder.endSelectionFromEnd(text.length - end);
    }

    _lastToken = token;
    return chunk;
  }

  /// Returns the number of characters past [offset] in the source where the
  /// selection start appears if it appears before `offset + length`.
  ///
  /// Returns `null` if the selection start has already been processed or is
  /// not within that range.
  int? _getSelectionStartWithin(int offset, int length) {
    // If there is no selection, do nothing.
    if (_source.selectionStart == null) return null;

    // If we've already passed it, don't consider it again.
    if (_passedSelectionStart) return null;

    var start = _source.selectionStart! - offset;

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
  int? _getSelectionEndWithin(int offset, int length) {
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
    if (_selectionEnd != null) return _selectionEnd!;

    var end = _source.selectionStart! + _source.selectionLength!;

    // If the selection bumps to the end of the source, pin it there.
    if (end == _source.text.length) {
      _selectionEnd = end;
      return end;
    }

    // Trim off any trailing whitespace. We want the selection to "rubberband"
    // around the selected non-whitespace tokens since the whitespace will
    // be munged by the formatter itself.
    while (end > _source.selectionStart!) {
      // Stop if we hit anything other than space, tab, newline or carriage
      // return.
      var char = _source.text.codeUnitAt(end - 1);
      if (char != 0x20 && char != 0x09 && char != 0x0a && char != 0x0d) {
        break;
      }

      end--;
    }

    _selectionEnd = end;
    return end;
  }

  /// Gets the 1-based line number that the beginning of [token] lies on.
  int _startLine(Token token) => _lineInfo.getLocation(token.offset).lineNumber;

  /// Gets the 1-based line number that the end of [token] lies on.
  int _endLine(Token token) => _lineInfo.getLocation(token.end).lineNumber;

  /// Gets the 1-based column number that the beginning of [token] lies on.
  int _startColumn(Token token) =>
      _lineInfo.getLocation(token.offset).columnNumber;
}

/// Synthetic node for any kind of binary operator.
///
/// Used to share formatting logic between binary operators, logic operators,
/// logic patterns, etc.
// TODO: Remove this and just use a record when those are available.
class BinaryNode {
  final AstNode left;
  final Token operator;
  final AstNode right;

  BinaryNode(this.left, this.operator, this.right);
}
