// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// ignore_for_file: avoid_dynamic_calls

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../ast_extensions.dart';
import '../comment_type.dart';
import '../constants.dart';
import '../dart_formatter.dart';
import '../profile.dart';
import '../source_code.dart';
import 'argument_list_visitor.dart';
import 'call_chain_visitor.dart';
import 'chunk.dart';
import 'chunk_builder.dart';
import 'rule/argument.dart';
import 'rule/combinator.dart';
import 'rule/rule.dart';
import 'rule/type_argument.dart';
import 'source_comment.dart';

/// Visits every token of the AST and passes all of the relevant bits to a
/// [ChunkBuilder].
final class SourceVisitor extends ThrowingAstVisitor {
  /// The builder for the block that is currently being visited.
  ChunkBuilder builder;

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

  /// The mapping for blocks that are managed by the argument list that contains
  /// them.
  ///
  /// When a block expression, such as a collection literal or a multiline
  /// string, appears inside an [ArgumentSublist], the argument list provides a
  /// rule for the body to split to ensure that all blocks split in unison. It
  /// also tracks the chunk before the argument that determines whether or not
  /// the block body is indented like an expression or a statement.
  ///
  /// Before a block argument is visited, [ArgumentSublist] binds itself to the
  /// beginning token of each block it controls. When we later visit that
  /// literal, we use the token to find that association.
  ///
  /// This mapping is also used for spread collection literals that appear
  /// inside control flow elements to ensure that when a "then" collection
  /// splits, the corresponding "else" one does too.
  final Map<Token, Rule> _blockRules = {};
  final Map<Token, Chunk> _blockPreviousChunks = {};

  /// Tracks tokens whose preceding comments have already been handled and
  /// written and thus don't need to be written when the token is.
  final Set<Token> _suppressPrecedingCommentsAndNewLines = {};

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(DartFormatter formatter, this._lineInfo, this._source)
    : builder = ChunkBuilder(formatter, _source);

  /// Runs the visitor on [node], formatting its contents.
  ///
  /// Returns a [SourceCode] containing the resulting formatted source and
  /// updated selection, if any.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  SourceCode run(AstNode node) {
    Profile.begin('SourceVisitor create Chunks');

    visit(node);

    // Output trailing comments.
    writePrecedingCommentsAndNewlines(node.endToken.next!);

    Profile.end('SourceVisitor create Chunks');

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

    if (node.arguments case var arguments?) {
      visitArgumentList(arguments, nestExpression: false);
    }

    builder.unnest();
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
  @override
  void visitArgumentList(ArgumentList node, {bool nestExpression = true}) {
    // Corner case: handle empty argument lists.
    if (node.arguments.isEmpty) {
      token(node.leftParenthesis);

      // If there is a comment inside the parens, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      return;
    }

    // If the argument list has a trailing comma, format it like a collection
    // literal where each argument goes on its own line, they are indented +2,
    // and the ")" ends up on its own line.
    if (node.arguments.hasCommaAfter) {
      _visitCollectionLiteral(
        node.leftParenthesis,
        node.arguments,
        node.rightParenthesis,
      );
      return;
    }

    if (nestExpression) builder.nestExpression();
    ArgumentListVisitor(this, node).visit();
    if (nestExpression) builder.unnest();
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
    token(node.assertKeyword);

    var arguments = <Expression>[node.condition];
    if (node.message != null) arguments.add(node.message!);

    // If the argument list has a trailing comma, format it like a collection
    // literal where each argument goes on its own line, they are indented +2,
    // and the ")" ends up on its own line.
    if (arguments.hasCommaAfter) {
      _visitCollectionLiteral(
        node.leftParenthesis,
        arguments,
        node.rightParenthesis,
      );
      return;
    }

    builder.nestExpression();
    var visitor = ArgumentListVisitor.forArguments(
      this,
      node.leftParenthesis,
      node.rightParenthesis,
      arguments,
    );
    visitor.visit();
    builder.unnest();
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    _simpleStatement(node, () {
      token(node.assertKeyword);

      var arguments = [node.condition];
      if (node.message != null) arguments.add(node.message!);

      // If the argument list has a trailing comma, format it like a collection
      // literal where each argument goes on its own line, they are indented +2,
      // and the ")" ends up on its own line.
      if (arguments.hasCommaAfter) {
        _visitCollectionLiteral(
          node.leftParenthesis,
          arguments,
          node.rightParenthesis,
        );
        return;
      }

      var visitor = ArgumentListVisitor.forArguments(
        this,
        node.leftParenthesis,
        node.rightParenthesis,
        arguments,
      );
      visitor.visit();
    });
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
      (expression) => BinaryNode(
        expression.leftOperand,
        expression.operator,
        expression.rightOperand,
      ),
    );
  }

  @override
  void visitBlock(Block node) {
    // Treat empty blocks specially. In most cases, they are not allowed to
    // split. However, an empty block as the then statement of an if with an
    // else is always split.
    if (!node.statements.canSplit(node.rightBracket)) {
      token(node.leftBracket);
      if (_splitEmptyBlock(node)) newline();
      token(node.rightBracket);
      return;
    }

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
  void visitCatchClauseParameter(CatchClauseParameter node) {
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
      var hasBody =
          declaration is ClassDeclaration ||
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

    _visitFunctionBody(null, node.parameters, node.body, () {
      // Check for redirects or initializer lists.
      if (node.redirectedConstructor != null) {
        _visitConstructorRedirects(node);
        builder.unnest();
      } else if (node.initializers.isNotEmpty) {
        _visitConstructorInitializers(node);

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

  void _visitConstructorInitializers(ConstructorDeclaration node) {
    var hasTrailingComma = node.parameters.parameters.hasCommaAfter;

    if (hasTrailingComma) {
      // Since the ")", "])", or "})" on the preceding line doesn't take up
      // much space, it looks weird to move the ":" onto it's own line. Instead,
      // keep it and the first initializer on the current line but add enough
      // space before it to line it up with any subsequent initializers.
      //
      //     Foo(
      //       parameter,
      //     )   : field = value,
      //           super();
      space();
      if (node.initializers.length > 1) {
        var padding = '  ';
        if (node.parameters.parameters.last.isNamed ||
            node.parameters.parameters.last.isOptionalPositional) {
          padding = ' ';
        }
        _writeText(padding, node.separator!);
      }

      // ":".
      token(node.separator);
      space();

      builder.indent(6);
    } else {
      // Shift the itself ":" forward.
      builder.indent(Indent.constructorInitializer);

      // If the parameters or initializers split, put the ":" on its own line.
      split();

      // ":".
      token(node.separator);
      space();

      // Try to line up the initializers with the first one that follows the ":"
      //
      //     Foo(notTrailing)
      //         : initializer = value,
      //           super(); // +2 from previous line.
      //
      //     Foo(
      //       trailing,
      //     ) : initializer = value,
      //         super(); // +4 from previous line.
      //
      // This doesn't work if there is a trailing comma in an optional
      // parameter, but we don't want to do a weird +5 alignment:
      //
      //     Foo({
      //       trailing,
      //     }) : initializer = value,
      //         super(); // Doesn't quite line up. :(
      builder.indent(2);
    }

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);
        newline();
      }

      node.initializers[i].accept(this);
    }

    builder.unindent();
    if (!hasTrailingComma) builder.unindent();
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

      // The '=' separator is preceded by a space, ":" is not.
      if (node.separator!.type == TokenType.EQ) space();
      token(node.separator);

      soloSplit(_assignmentCost(node.defaultValue!));
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

      visitArgumentList(arguments.argumentList, nestExpression: false);
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
    var afterConstants = node.constants.last.endToken.next!;
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

    _endBody(
      node.rightBracket,
      forceSplit:
          semicolon != null ||
          trailingComma != null ||
          node.members.isNotEmpty ||
          // If there is a line comment after an enum constant, it won't
          // automatically force the enum body to split since the rule for
          // the constants is the hard rule used by the entire block and its
          // hardening state doesn't actually change. Instead, look
          // explicitly for a line comment here.
          node.constants.containsLineComments(),
    );
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

    // Try to keep the "(...) => " with the start of the body for anonymous
    // functions.
    if (node.isFunctionExpressionBody) builder.startSpan();

    token(node.functionDefinition); // "=>".

    // Split after the "=>", using the rule created before the parameters
    // by _visitBody().
    split();

    // If the body is a binary operator expression, then we want to force the
    // split at `=>` if the operators split. See visitBinaryExpression().
    if (node.expression is! BinaryExpression) builder.endRule();

    if (node.isFunctionExpressionBody) builder.endSpan();

    // If this function invocation appears in an argument list with trailing
    // comma, don't add extra nesting to preserve normal indentation.
    var isArgWithTrailingComma = false;
    var parent = node.parent;
    if (parent is FunctionExpression) {
      isArgWithTrailingComma = parent.isTrailingCommaArgument;
    }

    if (!isArgWithTrailingComma) builder.startBlockArgumentNesting();
    builder.startSpan();
    visit(node.expression);
    builder.endSpan();
    if (!isArgWithTrailingComma) builder.endBlockArgumentNesting();

    if (node.expression is BinaryExpression) builder.endRule();

    token(node.semicolon);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    _simpleStatement(node, () {
      visit(node.expression);
    });
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    soloSplit();
    token(node.extendsKeyword);
    space();
    visit(node.superclass);
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
    if (node.onClause case var onClause?) {
      soloSplit();
      token(onClause.onKeyword);
      space();
      visit(onClause.extendedType);
    }
    space();
    builder.unnest();
    _visitBody(node.leftBracket, node.members, node.rightBracket);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    visitMetadata(node.metadata);

    builder.nestExpression();
    token(node.extensionKeyword);
    space();
    token(node.typeKeyword);
    token(node.constKeyword, before: space);
    space();
    token(node.name);

    builder.nestExpression();
    visit(node.typeParameters);
    visit(node.representation);
    builder.unnest();

    builder.startRule(CombinatorRule());
    visit(node.implementsClause);
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
      visit(node.typeParameters);
      visit(node.parameters);
      token(node.question);
      _endFormalParameter(node);
    });
  }

  @override
  void visitFormalParameterList(
    FormalParameterList node, {
    bool nestExpression = true,
  }) {
    // Corner case: empty parameter lists.
    if (node.parameters.isEmpty) {
      token(node.leftParenthesis);

      // If there is a comment, do allow splitting before it.
      if (node.rightParenthesis.precedingComments != null) soloZeroSplit();

      token(node.rightParenthesis);
      return;
    }

    // If the parameter list has a trailing comma, format it like a collection
    // literal where each parameter goes on its own line, they are indented +2,
    // and the ")" ends up on its own line.
    if (node.parameters.hasCommaAfter) {
      _visitTrailingCommaParameterList(node);
      return;
    }

    var requiredParams =
        node.parameters
            .where((param) => param is! DefaultFormalParameter)
            .toList();
    var optionalParams =
        node.parameters.whereType<DefaultFormalParameter>().toList();

    if (nestExpression) builder.nestExpression();
    token(node.leftParenthesis);

    PositionalRule? rule;
    if (requiredParams.isNotEmpty) {
      rule = PositionalRule(null, argumentCount: requiredParams.length);

      builder.startRule(rule);
      if (node.isFunctionExpressionBody) {
        // Don't allow splitting before the first argument (i.e. right after
        // the bare "(" in a lambda. Instead, just stuff a null chunk in there
        // to avoid confusing the arg rule.
        rule.beforeArgument(null);
      } else {
        // Split before the first argument.
        rule.beforeArgument(zeroSplit());
      }

      // Make sure record and function type parameter lists are indented.
      builder.startBlockArgumentNesting();
      builder.startSpan();

      for (var param in requiredParams) {
        visit(param);
        _writeCommaAfter(param);

        if (param != requiredParams.last) rule.beforeArgument(split());
      }

      builder.endBlockArgumentNesting();
      builder.endSpan();
      builder.endRule();
    }

    if (optionalParams.isNotEmpty) {
      var namedRule = NamedRule(null, 0, 0);
      if (rule != null) rule.addNamedArgsConstraints(namedRule);

      builder.startRule(namedRule);

      // Make sure multi-line default values, record types, and inner function
      // types are indented.
      builder.startBlockArgumentNesting();

      namedRule.beforeArgument(builder.split(space: requiredParams.isNotEmpty));

      // "[" or "{" for optional parameters.
      token(node.leftDelimiter);

      for (var param in optionalParams) {
        visit(param);
        _writeCommaAfter(param);

        if (param != optionalParams.last) namedRule.beforeArgument(split());
      }

      builder.endBlockArgumentNesting();
      builder.endRule();

      // "]" or "}" for optional parameters.
      token(node.rightDelimiter);
    }

    token(node.rightParenthesis);
    if (nestExpression) builder.unnest();
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
    visitNodes(node.loopVariable.metadata, between: split, after: split);
    visit(node.loopVariable);
    // TODO(rnystrom): we used to call builder.endRule() here, but now we call
    // it from visitForStatement2 after the `)`.  Is that ok?

    _visitForEachPartsFromIn(node);
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
    builder.nestExpression();

    // Allow the variables to stay unsplit even if the clauses split.
    builder.startRule();

    var declaration = node.variables;
    visitNodes(declaration.metadata, between: split, after: split);
    modifier(declaration.keyword);
    visit(declaration.type, after: space);

    visitCommaSeparatedNodes(declaration.variables, between: split);

    builder.endRule();
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
    _visitFunctionBody(node.typeParameters, node.parameters, node.body);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    // Try to keep the entire invocation one line.
    builder.startSpan();
    builder.nestExpression();

    visit(node.function);
    visit(node.typeArguments);
    visitArgumentList(node.argumentList, nestExpression: false);

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
      modifier(node.requiredKeyword);
      modifier(node.covariantKeyword);
      visit(node.returnType, after: space);
      // Try to keep the function's parameters with its name.
      builder.startSpan();
      token(node.name);
      _visitParameterSignature(node.typeParameters, node.parameters);
      token(node.question);
      builder.endSpan();
    });
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    builder.startLazyRule();
    builder.nestExpression();

    visit(node.returnType, after: split);
    token(node.functionKeyword);

    builder.unnest();
    builder.endRule();
    _visitParameterSignature(node.typeParameters, node.parameters);

    token(node.question);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    visitNodes(node.metadata, between: newline, after: newline);
    _simpleStatement(node, () {
      token(node.typedefKeyword);
      space();

      // If the typedef's type parameters split, split after the "=" too,
      // mainly to ensure the function's type parameters and parameters get
      // end up on successive lines with the same indentation.
      builder.startRule();

      token(node.name);
      visit(node.typeParameters);
      split();
      token(node.equals);

      builder.endRule();

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
      for (
        CollectionElement? thisNode = node;
        thisNode is IfElement;
        thisNode = thisNode.elseElement
      )
        thisNode,
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
        beforeBlock(spreadBracket, spreadRule, null);
      }
    }

    var elseSpreadBracket =
        ifElements.last.elseElement?.spreadCollectionBracket;
    if (elseSpreadBracket != null) {
      spreadBrackets[ifElements.last.elseElement!] = elseSpreadBracket;
      beforeBlock(elseSpreadBracket, spreadRule, null);
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

        // If the then clause is a non-spread collection or lambda, make sure
        // the body is indented.
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
      _visitIfCondition(
        element.ifKeyword,
        element.leftParenthesis,
        element.expression,
        element.caseClause,
        element.rightParenthesis,
      );

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
    _visitIfCondition(
      node.ifKeyword,
      node.leftParenthesis,
      node.expression,
      node.caseClause,
      node.rightParenthesis,
    );

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

      // The language specifies that configurations must appear after any `as`
      // clause but the parser incorrectly accepts them before it and code in
      // the wild relies on that. Instead of failing with an "unexpected output"
      // error, just preserve the order of the clauses if they are out of order.
      // See: https://github.com/dart-lang/sdk/issues/56641
      var wroteConfigurations = false;
      if (node.asKeyword case var asKeyword?
          when node.configurations.isNotEmpty &&
              node.configurations.first.ifKeyword.offset < asKeyword.offset) {
        _visitConfigurations(node.configurations);
        wroteConfigurations = true;
      }

      if (node.asKeyword != null) {
        soloSplit();
        token(node.deferredKeyword, after: space);
        token(node.asKeyword);
        space();
        visit(node.prefix);
      }

      if (!wroteConfigurations) {
        _visitConfigurations(node.configurations);
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
    token(node.leftBracket);
    soloZeroSplit();
    visit(node.index);
    token(node.rightBracket);
    builder.endSpan();
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    builder.startSpan();

    token(node.keyword, after: space);
    builder.startSpan(Cost.constructorName);

    // Start the expression nesting for the argument list here, in case this
    // is a generic constructor with type arguments. If it is, we need the type
    // arguments to be nested too so they get indented past the arguments.
    builder.nestExpression();
    visit(node.constructorName);

    builder.endSpan();
    visitArgumentList(node.argumentList, nestExpression: false);
    builder.endSpan();

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
      if (node.name case var name?) visit(name, before: space);
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
    _visitCollectionLiteral(
      node.leftBracket,
      node.elements,
      node.rightBracket,
      constKeyword: node.constKeyword,
      typeArguments: node.typeArguments,
      splitOuterCollection: true,
      cost: cost,
    );
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
        pattern.leftOperand,
        pattern.operator,
        pattern.rightOperand,
      ),
    );
  }

  @override
  void visitLogicalOrPattern(LogicalOrPattern node) {
    _visitBinary<LogicalOrPattern>(
      node,
      (pattern) => BinaryNode(
        pattern.leftOperand,
        pattern.operator,
        pattern.rightOperand,
      ),
    );
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
    _visitCollectionLiteral(
      node.leftBracket,
      node.elements,
      node.rightBracket,
      typeArguments: node.typeArguments,
    );
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
    // presence or absence of `new`/`const`.
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
      visitArgumentList(node.argumentList, nestExpression: false);
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
    visitNamedNode(node.name.label.token, node.name.colon, node.expression);
  }

  @override
  void visitNamedType(NamedType node) {
    if (node.importPrefix case var importPrefix?) {
      builder.startSpan();
      token(importPrefix.name);
      soloZeroSplit();
      token(importPrefix.period);
      token(node.name);
      builder.endSpan();
    } else {
      token(node.name);
    }

    visit(node.typeArguments);
    token(node.question);
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
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
    );
  }

  @override
  void visitMixinOnClause(MixinOnClause node) {
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
        visitNamedNode(fieldName.name!, fieldName.colon, node.pattern);
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
    PatternVariableDeclarationStatement node,
  ) {
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
    RedirectingConstructorInvocation node,
  ) {
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
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
      isRecord: true,
    );
  }

  @override
  void visitRecordPattern(RecordPattern node) {
    _visitCollectionLiteral(
      node.leftParenthesis,
      node.fields,
      node.rightParenthesis,
      isRecord: true,
    );
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
      _writeCommaAfter(field);
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
        _writeCommaAfter(field);
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
      force =
          node.positionalFields.length > 1 &&
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
    RecordTypeAnnotationNamedField node,
  ) {
    visitParameterMetadata(node.metadata, () {
      visit(node.type);
      token(node.name, before: space);
    });
  }

  @override
  void visitRecordTypeAnnotationPositionalField(
    RecordTypeAnnotationPositionalField node,
  ) {
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
  void visitRepresentationConstructorName(RepresentationConstructorName node) {
    token(node.period);
    token(node.name);
  }

  @override
  void visitRepresentationDeclaration(RepresentationDeclaration node) {
    visit(node.constructorName);

    token(node.leftParenthesis);

    var rule = PositionalRule(null, argumentCount: 1);

    builder.startRule(rule);
    rule.beforeArgument(zeroSplit());

    // Make sure record and function type parameter lists are indented.
    builder.startBlockArgumentNesting();
    builder.startSpan();

    visitParameterMetadata(node.fieldMetadata, () {
      builder.startLazyRule(Rule(Cost.parameterType));
      builder.nestExpression();

      visit(node.fieldType);
      _separatorBetweenTypeAndVariable(node.fieldType);
      token(node.fieldName);

      builder.unnest();
      builder.endRule();
    });

    builder.endBlockArgumentNesting();
    builder.endSpan();
    builder.endRule();

    token(node.rightParenthesis);
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
    _visitCollectionLiteral(
      node.leftBracket,
      node.elements,
      node.rightBracket,
      constKeyword: node.constKeyword,
      typeArguments: node.typeArguments,
      splitOuterCollection: true,
    );
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    _visitCombinator(node.keyword, node.shownNames);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      _beginFormalParameter(node);

      modifier(node.keyword);

      visit(node.type);
      if (node.name != null) _separatorBetweenTypeAndVariable(node.type);
      token(node.name);

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
      visit(node.typeParameters);
      visit(node.parameters);
      token(node.question);
      _endFormalParameter(node);
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    if (!node.cases.canSplit(node.rightBracket)) {
      // Don't allow splitting an empty switch expression.
      _visitSwitchValue(
        node.switchKeyword,
        node.leftParenthesis,
        node.expression,
        node.rightParenthesis,
      );
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

    _visitSwitchValue(
      node.switchKeyword,
      node.leftParenthesis,
      node.expression,
      node.rightParenthesis,
    );

    token(node.leftBracket);
    builder = builder.startBlock(space: node.cases.isNotEmpty);

    visitCommaSeparatedNodes(node.cases, between: split);

    var hasTrailingComma =
        node.cases.isNotEmpty && node.cases.last.commaAfter != null;

    // TODO(rnystrom): If there is a line comment at the end of a case, make
    // sure the switch expression splits. Looking for line comments explicitly
    // instead of having them harden the surrounding rules is a hack. But this
    // code will be going away when we move to the new Piece representation, so
    // going with something expedient.
    var forceSplit = node.cases.containsLineComments(node.rightBracket);

    _endBody(node.rightBracket, forceSplit: hasTrailingComma || forceSplit);
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
    _visitSwitchValue(
      node.switchKeyword,
      node.leftParenthesis,
      node.expression,
      node.rightParenthesis,
    );
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
  void _visitSwitchValue(
    Token switchKeyword,
    Token leftParenthesis,
    Expression value,
    Token rightParenthesis,
  ) {
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

    _visitAssignment(
      node.equals!,
      node.initializer!,
      nest: hasMultipleVariables,
    );
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

    visitNodes(
      directive.metadata,
      between: newline,
      after: isFirst ? oneOrTwoNewlines : newline,
    );
  }

  /// Visits metadata annotations on parameters and type parameters.
  ///
  /// Unlike other annotations, these are allowed to stay on the same line as
  /// the parameter.
  void visitParameterMetadata(
    NodeList<Annotation> metadata,
    void Function() visitParameter,
  ) {
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

  /// Visits [node], which may be in an argument list controlled by [rule].
  ///
  /// This is called directly by [ArgumentListVisitor] so that it can pass in
  /// the surrounding named argument rule. That way, this can ensure that a
  /// split between the name and argument forces the argument list to split
  /// too.
  void visitNamedArgument(NamedExpression node, [NamedRule? rule]) {
    visitNamedNode(
      node.name.label.token,
      node.name.colon,
      node.expression,
      rule,
    );
  }

  /// Visits syntax of the form `identifier: <node>`: a named argument or a
  /// named record field.
  void visitNamedNode(
    Token name,
    Token colon,
    AstNode node, [
    NamedRule? rule,
  ]) {
    builder.nestExpression();
    builder.startSpan();
    token(name);
    token(colon);

    // Don't allow a split between a name and a collection. Instead, we want
    // the collection itself to split, or to split before the argument.
    if (node is ListLiteral ||
        node is SetOrMapLiteral ||
        node is RecordLiteral) {
      space();
    } else {
      var split = soloSplit();
      if (rule != null) split.constrainWhenSplit(rule);
    }

    visit(node);
    builder.endSpan();
    builder.unnest();
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
  void _visitAssignment(
    Token equalsOperator,
    Expression rightHandSide, {
    bool nest = false,
  }) {
    space();
    token(equalsOperator);

    if (nest) builder.nestExpression(now: true);

    soloSplit(_assignmentCost(rightHandSide));
    builder.startSpan();
    visit(rightHandSide);
    builder.endSpan();

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
    T node,
    BinaryNode Function(T node) destructureNode, {
    int? precedence,
    bool nest = true,
  }) {
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
    WithClause? withClause,
    ImplementsClause? implementsClause,
  ) {
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
    Token leftBracket,
    Token rightBracket,
    List<AstNode> nodes,
  ) {
    var rule = TypeArgumentRule();
    builder.startLazyRule(rule);
    builder.startSpan();
    builder.nestExpression();

    token(leftBracket);
    rule.beforeArgument(zeroSplit());

    // Set the block nesting in case an argument is a function type with a
    // trailing comma or a record type.
    builder.startBlockArgumentNesting();

    for (var node in nodes) {
      visit(node);

      // Write the comma separator.
      if (node != nodes.last) {
        var comma = node.endToken.next;

        // TODO(rnystrom): There is a bug in analyzer where the end token of a
        // nullable record type is the ")" and not the "?". This works around
        // that. Remove that's fixed.
        if (comma?.lexeme == '?') comma = comma?.next;

        token(comma);
        rule.beforeArgument(split());
      }
    }

    token(rightBracket);

    builder.endBlockArgumentNesting();
    builder.unnest();
    builder.endSpan();
    builder.endRule();
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

    // Nest the signature in case we have to split between the return type and
    // name.
    builder.nestExpression();
    builder.startSpan();
    modifier(externalKeyword);
    modifier(modifierKeyword);
    visit(returnType, after: soloSplit);
    modifier(propertyKeyword);
    modifier(operatorKeyword);
    token(name);
    builder.endSpan();

    _visitFunctionBody(typeParameters, formalParameters, body, () {
      // If the body is a block, we need to exit nesting before we hit the body
      // indentation, but we do want to wrap it around the parameters.
      if (body is! ExpressionFunctionBody) builder.unnest();
    });

    // If it's an expression, we want to wrap the nesting around that so that
    // the body gets nested farther.
    if (body is ExpressionFunctionBody) builder.unnest();
  }

  /// Visit the given function [parameters] followed by its [body], printing a
  /// space before it if it's not empty.
  ///
  /// If [beforeBody] is provided, it is invoked before the body is visited.
  void _visitFunctionBody(
    TypeParameterList? typeParameters,
    FormalParameterList? parameters,
    FunctionBody body, [
    void Function()? beforeBody,
  ]) {
    // If the body is "=>", add an extra level of indentation around the
    // parameters and a rule that spans the parameters and the "=>". This
    // ensures that if the parameters wrap, they wrap more deeply than the "=>"
    // does, as in:
    //
    //     someFunction(parameter,
    //             parameter, parameter) =>
    //         "the body";
    //
    // Also, it ensures that if the parameters wrap, we split at the "=>" too
    // to avoid:
    //
    //     someFunction(parameter,
    //         parameter) => function(
    //         argument);
    //
    // This is confusing because it looks like those two lines are at the same
    // level when they are actually unrelated. Splitting at "=>" forces:
    //
    //     someFunction(parameter,
    //             parameter) =>
    //         function(
    //             argument);
    if (body is ExpressionFunctionBody) {
      builder.nestExpression();

      // This rule is ended by visitExpressionFunctionBody().
      builder.startLazyRule(Rule(Cost.arrow));
    }

    _visitParameterSignature(typeParameters, parameters);

    if (beforeBody != null) beforeBody();
    visit(body);

    if (body is ExpressionFunctionBody) builder.unnest();
  }

  /// Visits the type parameters (if any) and formal parameters of a method
  /// declaration, function declaration, or generic function type.
  void _visitParameterSignature(
    TypeParameterList? typeParameters,
    FormalParameterList? parameters,
  ) {
    // Start the nesting for the parameters here, so they indent past the
    // type parameters too, if any.
    builder.nestExpression();

    visit(typeParameters);
    if (parameters != null) {
      visitFormalParameterList(parameters, nestExpression: false);
    }

    builder.unnest();
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
  void visitNodes(
    Iterable<AstNode> nodes, {
    void Function()? before,
    void Function()? between,
    void Function()? after,
  }) {
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
  void visitCommaSeparatedNodes(
    Iterable<AstNode> nodes, {
    void Function()? between,
  }) {
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
    Token leftBracket,
    List<AstNode> elements,
    Token rightBracket, {
    Token? constKeyword,
    TypeArgumentList? typeArguments,
    int? cost,
    bool splitOuterCollection = false,
    bool isRecord = false,
  }) {
    modifier(constKeyword);

    // Don't use the normal type argument list formatting code because we don't
    // want to allow splitting before the "<" since there is no preceding
    // identifier and it looks weird to have a "<" hanging by itself. Prevents:
    //
    //   var list = <
    //       LongTypeName<
    //           TypeArgument,
    //           TypeArgument>>[];
    if (typeArguments != null) {
      builder.startSpan();
      builder.nestExpression();
      token(typeArguments.leftBracket);
      builder.startRule(Rule(Cost.typeArgument));

      for (var typeArgument in typeArguments.arguments) {
        visit(typeArgument);

        // Write the comma separator.
        if (typeArgument != typeArguments.arguments.last) {
          var comma = typeArgument.endToken.next;

          // TODO(rnystrom): There is a bug in analyzer where the end token of a
          // nullable record type is the ")" and not the "?". This works around
          // that. Remove once that's fixed.
          if (comma?.lexeme == '?') comma = comma?.next;

          token(comma);
          split();
        }
      }

      token(typeArguments.rightBracket);
      builder.endRule();
      builder.unnest();
      builder.endSpan();
    }

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

    _beginBody(leftBracket);

    // If a collection contains a line comment, we assume it's a big complex
    // blob of data with some documented structure. In that case, the user
    // probably broke the elements into lines deliberately, so preserve those.
    if (elements.containsLineComments(rightBracket)) {
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
        _writeCommaAfter(element);
      }

      builder.endRule();
    } else {
      for (var element in elements) {
        builder.split(nest: false, space: element != elements.first);
        visit(element);
        _writeCommaAfter(element);
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

    _endBody(rightBracket, forceSplit: force);
  }

  /// Writes [parameters], which is assumed to have a trailing comma after the
  /// last parameter.
  ///
  /// Parameter lists with trailing commas are formatted differently from
  /// regular parameter lists. They are treated more like collection literals.
  ///
  /// We don't reuse [_visitCollectionLiteral] here because there are enough
  /// weird differences around optional parameters that it's easiest just to
  /// give them their own method.
  void _visitTrailingCommaParameterList(FormalParameterList parameters) {
    // Can't have a trailing comma if there are no parameters.
    assert(parameters.parameters.isNotEmpty);

    // Always split the parameters.
    builder.startRule(Rule.hard());

    token(parameters.leftParenthesis);

    // Find the parameter immediately preceding the optional parameters (if
    // there are any).
    FormalParameter? lastRequired;
    for (var i = 0; i < parameters.parameters.length; i++) {
      if (parameters.parameters[i] is DefaultFormalParameter) {
        if (i > 0) lastRequired = parameters.parameters[i - 1];
        break;
      }
    }

    // If all parameters are optional, put the "[" or "{" right after "(".
    if (parameters.parameters.first is DefaultFormalParameter) {
      token(parameters.leftDelimiter);
    }

    // Process the parameters as a separate set of chunks.
    builder = builder.startBlock();

    for (var parameter in parameters.parameters) {
      builder.writeNewline();
      visit(parameter);
      _writeCommaAfter(parameter);

      // If the optional parameters start after this one, put the delimiter
      // at the end of its line.
      if (parameter == lastRequired) {
        space();
        token(parameters.leftDelimiter);
        lastRequired = null;
      }
    }

    // Put comments before the closing ")", "]", or "}" inside the block.
    var firstDelimiter =
        parameters.rightDelimiter ?? parameters.rightParenthesis;
    if (firstDelimiter.precedingComments != null) {
      builder.writeNewline();
      writePrecedingCommentsAndNewlines(firstDelimiter);
    }

    builder = builder.endBlock();
    builder.endRule();

    // Now write the delimiter itself.
    _writeText(firstDelimiter.lexeme, firstDelimiter);
    if (firstDelimiter != parameters.rightParenthesis) {
      token(parameters.rightParenthesis);
    }
  }

  /// Begins writing a formal parameter of any kind.
  void _beginFormalParameter(FormalParameter node) {
    builder.startLazyRule(Rule(Cost.parameterType));
    builder.nestExpression();
    modifier(node.requiredKeyword);
    modifier(node.covariantKeyword);
  }

  /// Ends writing a formal parameter of any kind.
  void _endFormalParameter(FormalParameter node) {
    builder.unnest();
    builder.endRule();
  }

  /// Visits the `if (<expr> [case <pattern> [when <expr>]])` header of an if
  /// statement or element.
  void _visitIfCondition(
    Token ifKeyword,
    Token leftParenthesis,
    AstNode condition,
    CaseClause? caseClause,
    Token rightParenthesis,
  ) {
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
  void _separatorBetweenTypeAndVariable(
    TypeAnnotation? type, {
    bool isSolo = false,
  }) {
    if (type == null) return;

    var isBlockType = false;
    if (type is GenericFunctionType) {
      // Function types get block-like formatting if they have a trailing comma.
      isBlockType =
          type.parameters.parameters.isNotEmpty &&
          type.parameters.parameters.last.hasCommaAfter;
    } else if (type is RecordTypeAnnotation) {
      // Record types always have block-like formatting.
      isBlockType = true;
    }

    if (isBlockType) {
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

  /// Gets the cost to split at an assignment (or `:` in the case of a named
  /// default value) with the given [rightHandSide].
  ///
  /// "Block-like" expressions (collections and cascades) bind a bit tighter
  /// because it looks better to have code like:
  ///
  ///     var list = [
  ///       element,
  ///       element,
  ///       element
  ///     ];
  ///
  ///     var builder = new SomeBuilderClass()
  ///       ..method()
  ///       ..method();
  ///
  /// over:
  ///
  ///     var list =
  ///         [element, element, element];
  ///
  ///     var builder =
  ///         new SomeBuilderClass()..method()..method();
  int _assignmentCost(Expression rightHandSide) {
    if (rightHandSide is ListLiteral) return Cost.assignBlock;
    if (rightHandSide is SetOrMapLiteral) return Cost.assignBlock;
    if (rightHandSide is CascadeExpression) return Cost.assignBlock;

    return Cost.assign;
  }

  /// Begins writing a bracket-delimited body whose contents are a nested
  /// block chunk.
  ///
  /// If [space] is `true`, writes a space after [leftBracket] when not split.
  ///
  /// Writes the delimiter (with a space after it when unsplit if [space] is
  /// `true`).
  void _beginBody(Token leftBracket, {bool space = false}) {
    token(leftBracket);

    // Create a rule for whether or not to split the block contents. If this
    // literal is associated with an argument list or if element that wants to
    // handle splitting and indenting it, use its rule. Otherwise, use a
    // default rule.
    builder.startRule(_blockRules[leftBracket]);

    // Process the contents as a separate set of chunks.
    builder = builder.startBlock(
      argumentChunk: _blockPreviousChunks[leftBracket],
      space: space,
    );
  }

  /// Ends the body started by a call to [_beginBody()].
  ///
  /// If [space] is `true`, writes a space before the closing bracket when not
  /// split. If [forceSplit] is `true`, forces the body to split.
  void _endBody(Token rightBracket, {bool forceSplit = false}) {
    // Put comments before the closing delimiter inside the block.
    var hasLeadingNewline = writePrecedingCommentsAndNewlines(rightBracket);

    builder = builder.endBlock(forceSplit: hasLeadingNewline || forceSplit);

    builder.endRule();

    // Now write the delimiter itself.
    _writeText(rightBracket.lexeme, rightBracket);
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
    token(keyword);

    rule.addName(split());
    visitCommaSeparatedNodes(nodes, between: () => rule.addName(split()));

    builder.unnest();
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
    token((node as dynamic).semicolon as Token);
    builder.unnest();
  }

  /// Marks the block that starts with [token] as being controlled by
  /// [rule] and following [previousChunk].
  ///
  /// When the block is visited, these will determine the indentation and
  /// splitting rule for the block. These are used for handling block-like
  /// expressions inside argument lists and spread collections inside if
  /// elements.
  void beforeBlock(Token token, Rule rule, [Chunk? previousChunk]) {
    _blockRules[token] = rule;
    if (previousChunk != null) _blockPreviousChunks[token] = previousChunk;
  }

  /// Writes the brace-delimited body containing [nodes].
  void _visitBody(Token leftBracket, List<AstNode> nodes, Token rightBracket) {
    // Don't allow splitting in an empty body.
    if (!nodes.canSplit(rightBracket)) {
      token(leftBracket);
      token(rightBracket);
      return;
    }

    _beginBody(leftBracket);
    _visitBodyContents(nodes);
    _endBody(rightBracket, forceSplit: nodes.isNotEmpty);
  }

  static final _lineTerminatorRE = RegExp(r'\r\n?|\n');

  /// Writes the string literal [string] to the output.
  ///
  /// Splits multiline strings into separate chunks so that the line splitter
  /// can handle them correctly.
  void _writeStringLiteral(Token string) {
    // Since we output the string literal manually, ensure any preceding
    // comments are written first.
    writePrecedingCommentsAndNewlines(string);

    var lines = string.lexeme.split(_lineTerminatorRE);
    var offset = string.offset;
    var firstLine = lines.first;
    if (lines.length > 1) {
      // Special case for multiline string which contains
      // at least one newline.
      _writeStringFirstLine(firstLine, string, offset: offset);
    } else {
      _writeText(firstLine, string, offset: offset);
    }
    offset += firstLine.length;

    for (var i = 1; i < lines.length; i++) {
      var line = lines[i];
      builder.writeNewline(flushLeft: true, nest: true);
      offset++;
      _writeText(line, string, offset: offset, mergeEmptySplits: false);
      offset += line.length;
    }
  }

  /// Writes the first line of a multi-line string.
  ///
  /// If the string is a multiline string, and it has only whitespace
  /// and escaped whitespace before a first line break,
  /// omit the non-escaped trailing whitespace.
  /// Normalize escaped non-final whitspace to spaces.
  ///
  /// More specifically:
  /// If a multiline string literal contains at least one line-break
  /// (a CR, LF or CR+LF) as part of the source character content
  /// (characters inside interpolation expressions do not count),
  /// and the source characters from the starting quote to the first
  /// line-break contains only the characters space, tab and backslash,
  /// with no two adjacent backslashes, then that part of the string source,
  /// including the following line break, is excluded from particiapting
  /// code points to the string value.
  ///
  /// This function normalizes such excluded character sequences
  /// to just the back-slashes, separated by space characters.
  void _writeStringFirstLine(String line, Token string, {required int offset}) {
    // Detect leading whitespace on the first line of multiline strings.
    var quoteStart = line.startsWith('r') ? 1 : 0;
    var quoteEnd = quoteStart + 3;
    var backslashCount = 0;
    if (line.length > quoteEnd &&
        (line.startsWith("'''", quoteStart) ||
            line.startsWith('"""', quoteStart))) {
      // Start of a multiline string literal.
      // Check if rest of the line is whitespace, possibly preceded by
      // backslash, or has a single trailing backslash preceding the newline.
      // Count the backslashes.
      var cursor = quoteEnd;
      const backslash = 0x5c;
      const space = 0x20;
      const tab = 0x09;

      do {
        var char = line.codeUnitAt(cursor);
        if (char == backslash) {
          cursor += 1;
          backslashCount++;
          if (cursor >= line.length) {
            break;
          }
          char = line.codeUnitAt(cursor);
        }
        if (char != space && char != tab) break;
        cursor++;
      } while (cursor < line.length);
      if (cursor == line.length) {
        // No invalid character sequence found before end of line.
        // Normalize the ignored "escaped" whitespace which has no
        // effect on string content.
        var firstLineText = line.substring(0, quoteEnd);
        if (backslashCount > 0) {
          var buffer = StringBuffer(firstLineText);
          buffer.write(r'\');
          while (--backslashCount > 0) {
            buffer.write(r' \');
          }
          firstLineText = buffer.toString();
        }
        _writeText(firstLineText, string, offset: offset);
        return;
      }
    }
    _writeText(line, string, offset: offset);
  }

  /// Write the comma token following [node], if there is one.
  void _writeCommaAfter(AstNode node) {
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

    // If the token's comments are already handled, do not write them here.
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
        type = CommentType.doc;
      } else if (comment.type == TokenType.SINGLE_LINE_COMMENT) {
        type = CommentType.line;
      } else if (commentLine == previousLine || commentLine == tokenLine) {
        type = CommentType.inlineBlock;
      }

      var sourceComment = SourceComment(
        text,
        type,
        linesBefore,
        flushLeft: flushLeft,
      );

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
  /// Usually, [text] is simply [token]'s lexeme, but for multiline strings, or
  /// a couple of other cases, it will be different.
  ///
  /// If [offset] is given, uses that for calculating selection location.
  /// Otherwise, uses the offset of [token].
  void _writeText(
    String text,
    Token token, {
    int? offset,
    bool mergeEmptySplits = true,
  }) {
    offset ??= token.offset;

    builder.write(text, mergeEmptySplits: mergeEmptySplits);

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
final class BinaryNode {
  final AstNode left;
  final Token operator;
  final AstNode right;

  BinaryNode(this.left, this.operator, this.right);
}
