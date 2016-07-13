// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'argument_list_visitor.dart';
import 'call_chain_visitor.dart';
import 'chunk.dart';
import 'chunk_builder.dart';
import 'dart_formatter.dart';
import 'rule/argument.dart';
import 'rule/combinator.dart';
import 'rule/metadata.dart';
import 'rule/rule.dart';
import 'rule/type_argument.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// Visits every token of the AST and passes all of the relevant bits to a
/// [ChunkBuilder].
class SourceVisitor implements AstVisitor {
  /// The builder for the block that is currently being visited.
  ChunkBuilder builder;

  final DartFormatter _formatter;

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

  /// The stack of current rules for handling parameter metadata.
  ///
  /// Each time a parameter (or type parameter) list is begun, a single rule
  /// for all of the metadata annotations on parameters in that list is pushed
  /// onto this stack. We reuse this rule for all annotations so that they split
  /// in unison.
  final List<MetadataRule> _metadataRules = [];

  /// The mapping for collection literals that are managed by the argument
  /// list that contains them.
  ///
  /// When a collection literal appears inside an [ArgumentSublist], the
  /// argument list provides a rule for the body to split to ensure that all
  /// collections split in unison. It also tracks the chunk before the
  /// argument that determines whether or not the collection body is indented
  /// like an expression or a statement.
  ///
  /// Before a collection literal argument is visited, [ArgumentSublist] binds
  /// itself to the left bracket token of each collection literal it controls.
  /// When we later visit that literal, we use the token to find that
  /// association.
  final Map<Token, ArgumentSublist> _collectionArgumentLists = {};

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  SourceVisitor(this._formatter, this._lineInfo, this._source) {
    builder = new ChunkBuilder(_formatter, _source);
  }

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
    return builder.end();
  }

  visitAdjacentStrings(AdjacentStrings node) {
    builder.startSpan();
    builder.startRule();
    visitNodes(node.strings, between: splitOrNewline);
    builder.endRule();
    builder.endSpan();
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

    new ArgumentListVisitor(this, node).visit();
  }

  visitAsExpression(AsExpression node) {
    builder.startSpan();
    visit(node.expression);
    soloSplit();
    token(node.asOperator);
    space();
    visit(node.type);
    builder.endSpan();
  }

  visitAssertStatement(AssertStatement node) {
    _simpleStatement(node, () {
      token(node.assertKeyword);

      var arguments = [node.condition];
      if (node.message != null) arguments.add(node.message);

      var visitor = new ArgumentListVisitor.forArguments(
          this, node.leftParenthesis, node.rightParenthesis, arguments);
      visitor.visit();
    });
  }

  visitAssignmentExpression(AssignmentExpression node) {
    builder.nestExpression();

    visit(node.leftHandSide);
    _visitAssignment(node.operator, node.rightHandSide);

    builder.unnest();
  }

  visitAwaitExpression(AwaitExpression node) {
    token(node.awaitKeyword);
    space();
    visit(node.expression);
  }

  visitBinaryExpression(BinaryExpression node) {
    builder.startSpan();

    // If a binary operator sequence appears immediately after a `=>`, don't
    // add an extra level of nesting. Instead, let the subsequent operands line
    // up with the first, as in:
    //
    //     method() =>
    //         argument &&
    //         argument &&
    //         argument;
    var isArrowBody = node.parent is ExpressionFunctionBody;
    if (!isArrowBody) builder.nestExpression();

    // Start lazily so we don't force the operator to split if a line comment
    // appears before the first operand.
    builder.startLazyRule();

    // Flatten out a tree/chain of the same precedence. If we split on this
    // precedence level, we will break all of them.
    var precedence = node.operator.type.precedence;

    traverse(Expression e) {
      if (e is BinaryExpression && e.operator.type.precedence == precedence) {
        traverse(e.leftOperand);

        space();
        token(e.operator);

        split();
        traverse(e.rightOperand);
      } else {
        visit(e);
      }
    }

    // Blocks as operands to infix operators should always nest like regular
    // operands. (Granted, this case is exceedingly rare in real code.)
    builder.startBlockArgumentNesting();

    traverse(node);

    builder.endBlockArgumentNesting();

    if (!isArrowBody) builder.unnest();
    builder.endSpan();
    builder.endRule();
  }

  visitBlock(Block node) {
    // Don't allow splitting in an empty block.
    if (node.statements.isEmpty &&
        node.rightBracket.precedingComments == null) {
      token(node.leftBracket);
      token(node.rightBracket);
      return;
    }

    // For a block that is not a function body, just bump the indentation and
    // keep it in the current block.
    if (node.parent is! BlockFunctionBody) {
      _writeBody(node.leftBracket, node.rightBracket, body: () {
        visitNodes(node.statements, between: oneOrTwoNewlines, after: newline);
      });
      return;
    }

    _startLiteralBody(node.leftBracket);
    visitNodes(node.statements, between: oneOrTwoNewlines, after: newline);
    _endLiteralBody(node.rightBracket, forceSplit: node.statements.isNotEmpty);
  }

  visitBlockFunctionBody(BlockFunctionBody node) {
    // Space after the parameter list.
    space();

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
      token(node.breakKeyword);
      visit(node.label, before: space);
    });
  }

  visitCascadeExpression(CascadeExpression node) {
    // If the target of the cascade is a method call (or chain of them), we
    // treat the nesting specially. Normally, you would end up with:
    //
    //     receiver
    //           .method()
    //           .method()
    //       ..cascade()
    //       ..cascade();
    //
    // This is logical, since the method chain is an operand of the cascade
    // expression, so it's more deeply nested. But it looks wrong, so we leave
    // the method chain's nesting active until after the cascade sections to
    // force the *cascades* to be deeper because it looks better:
    //
    //     receiver
    //         .method()
    //         .method()
    //           ..cascade()
    //           ..cascade();
    if (node.target is MethodInvocation) {
      new CallChainVisitor(this, node.target).visit(unnest: false);
    } else {
      visit(node.target);
    }

    builder.nestExpression(indent: Indent.cascade, now: true);
    builder.startBlockArgumentNesting();

    // If the cascade sections have consistent names they can be broken
    // normally otherwise they always get their own line.
    if (_allowInlineCascade(node.cascadeSections)) {
      builder.startRule();
      zeroSplit();
      visitNodes(node.cascadeSections, between: zeroSplit);
      builder.endRule();
    } else {
      builder.startRule(new Rule.hard());
      zeroSplit();
      visitNodes(node.cascadeSections, between: zeroSplit);
      builder.endRule();
    }

    builder.endBlockArgumentNesting();
    builder.unnest();

    if (node.target is MethodInvocation) builder.unnest();
  }

  /// Whether a cascade should be allowed to be inline as opposed to one
  /// expression per line.
  bool _allowInlineCascade(List<Expression> sections) {
    if (sections.length < 2) return true;

    var name;
    // We could be more forgiving about what constitutes sections with
    // consistent names but for now we require all sections to have the same
    // method name.
    for (var expression in sections) {
      if (expression is MethodInvocation) {
        if (name == null) {
          name = expression.methodName.name;
        } else if (name != expression.methodName.name) {
          return false;
        }
      } else {
        return false;
      }
    }
    return true;
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
    visitMetadata(node.metadata);

    builder.nestExpression();
    modifier(node.abstractKeyword);
    token(node.classKeyword);
    space();
    visit(node.name);
    visit(node.typeParameters);
    visit(node.extendsClause);

    builder.startRule(new CombinatorRule());
    visit(node.withClause);
    visit(node.implementsClause);
    builder.endRule();

    visit(node.nativeClause, before: space);
    space();

    builder.unnest();
    _writeBody(node.leftBracket, node.rightBracket, body: () {
      if (node.members.isNotEmpty) {
        for (var member in node.members) {
          visit(member);

          if (member == node.members.last) {
            newline();
            break;
          }

          var needsDouble = false;
          if (member is ClassDeclaration) {
            // Add a blank line after classes.
            twoNewlines();
          } else if (member is MethodDeclaration) {
            // Add a blank line after non-empty block methods.
            if (member.body is BlockFunctionBody) {
              var body = member.body as BlockFunctionBody;
              needsDouble = body.block.statements.isNotEmpty;
            }
          }

          if (needsDouble) {
            twoNewlines();
          } else {
            // Variables and arrow-bodied members can be more tightly packed if
            // the user wants to group things together.
            oneOrTwoNewlines();
          }
        }
      }
    });
  }

  visitClassTypeAlias(ClassTypeAlias node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.abstractKeyword);
      token(node.typedefKeyword);
      space();
      visit(node.name);
      visit(node.typeParameters);
      space();
      token(node.equals);
      space();

      visit(node.superclass);

      builder.startRule(new CombinatorRule());
      visit(node.withClause);
      visit(node.implementsClause);
      builder.endRule();
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

    if (node.declarations.isNotEmpty) {
      var needsDouble = true;

      for (var declaration in node.declarations) {
        // Add a blank line before classes.
        if (declaration is ClassDeclaration) needsDouble = true;

        if (needsDouble) {
          twoNewlines();
        } else {
          // Variables and arrow-bodied members can be more tightly packed if
          // the user wants to group things together.
          oneOrTwoNewlines();
        }

        visit(declaration);

        needsDouble = false;
        if (declaration is ClassDeclaration) {
          // Add a blank line after classes.
          needsDouble = true;
        } else if (declaration is FunctionDeclaration) {
          // Add a blank line after non-empty block functions.
          if (declaration.functionExpression.body is BlockFunctionBody) {
            var body = declaration.functionExpression.body as BlockFunctionBody;
            needsDouble = body.block.statements.isNotEmpty;
          }
        }
      }
    }
  }

  visitConditionalExpression(ConditionalExpression node) {
    builder.nestExpression();

    // Push any block arguments all the way past the leading "?" and ":".
    builder.nestExpression(indent: Indent.block, now: true);
    builder.startBlockArgumentNesting();
    builder.unnest();

    visit(node.condition);

    builder.startSpan();

    // If we split after one clause in a conditional, always split after both.
    builder.startRule();
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

    builder.endRule();
    builder.endSpan();
    builder.endBlockArgumentNesting();
    builder.unnest();
  }

  visitConfiguration(Configuration node) {
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
    visit(node.libraryUri);
  }

  visitConstructorDeclaration(ConstructorDeclaration node) {
    visitMetadata(node.metadata);

    modifier(node.externalKeyword);
    modifier(node.constKeyword);
    modifier(node.factoryKeyword);
    visit(node.returnType);
    token(node.period);
    visit(node.name);

    // Make the rule for the ":" span both the preceding parameter list and
    // the entire initialization list. This ensures that we split before the
    // ":" if the parameters and initialization list don't all fit on one line.
    builder.startRule();

    // If the redirecting constructor happens to wrap, we want to make sure
    // the parameter list gets more deeply indented.
    if (node.redirectedConstructor != null) builder.nestExpression();

    _visitBody(node.parameters, node.body, () {
      // Check for redirects or initializer lists.
      if (node.redirectedConstructor != null) {
        _visitConstructorRedirects(node);
        builder.unnest();
      } else if (node.initializers.isNotEmpty) {
        _visitConstructorInitializers(node);
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
    // Shift the ":" forward.
    builder.indent(Indent.constructorInitializer);

    split();
    token(node.separator); // ":".
    space();

    // Shift everything past the ":".
    builder.indent();

    for (var i = 0; i < node.initializers.length; i++) {
      if (i > 0) {
        // Preceding comma.
        token(node.initializers[i].beginToken.previous);
        newline();
      }

      node.initializers[i].accept(this);
    }

    builder.unindent();
    builder.unindent();

    // End the rule for ":" after all of the initializers.
    builder.endRule();
  }

  visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    builder.nestExpression();

    token(node.thisKeyword);
    token(node.period);
    visit(node.fieldName);

    _visitAssignment(node.equals, node.expression);

    builder.unnest();
  }

  visitConstructorName(ConstructorName node) {
    visit(node.type);
    token(node.period);
    visit(node.name);
  }

  visitContinueStatement(ContinueStatement node) {
    _simpleStatement(node, () {
      token(node.continueKeyword);
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
      builder.startSpan();
      builder.nestExpression();

      // The '=' separator is preceded by a space, ":" is not.
      if (node.separator.type == TokenType.EQ) space();
      token(node.separator);

      soloSplit(_assignmentCost(node.defaultValue));
      visit(node.defaultValue);

      builder.unnest();
      builder.endSpan();
    }
  }

  visitDoStatement(DoStatement node) {
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

  visitDottedName(DottedName node) {
    for (var component in node.components) {
      // Write the preceding ".".
      if (component != node.components.first) {
        token(component.beginToken.previous);
      }

      visit(component);
    }
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
    visitMetadata(node.metadata);

    token(node.enumKeyword);
    space();
    visit(node.name);
    space();

    _writeBody(node.leftBracket, node.rightBracket, space: true, body: () {
      visitCommaSeparatedNodes(node.constants, between: split);
    });
  }

  visitExportDirective(ExportDirective node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.uri);

      _visitConfigurations(node.configurations);

      builder.startRule(new CombinatorRule());
      visitNodes(node.combinators);
      builder.endRule();
    });
  }

  visitExpressionFunctionBody(ExpressionFunctionBody node) {
    // Space after the parameter list.
    space();

    // The "async" or "sync" keyword.
    token(node.keyword, after: space);

    // Try to keep the "(...) => " with the start of the body for anonymous
    // functions.
    if (_isInLambda(node)) builder.startSpan();

    token(node.functionDefinition); // "=>".

    // Split after the "=>", using the rule created before the parameters
    // by _visitBody().
    split();

    // If the body is a binary operator expression, then we want to force the
    // split at `=>` if the operators split. See visitBinaryExpression().
    if (node.expression is! BinaryExpression) builder.endRule();

    if (_isInLambda(node)) builder.endSpan();

    builder.startBlockArgumentNesting();
    builder.startSpan();
    visit(node.expression);
    builder.endSpan();
    builder.endBlockArgumentNesting();

    if (node.expression is BinaryExpression) builder.endRule();

    token(node.semicolon);
  }

  visitExpressionStatement(ExpressionStatement node) {
    _simpleStatement(node, () {
      visit(node.expression);
    });
  }

  visitExtendsClause(ExtendsClause node) {
    soloSplit();
    token(node.extendsKeyword);
    space();
    visit(node.superclass);
  }

  visitFieldDeclaration(FieldDeclaration node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      modifier(node.staticKeyword);
      visit(node.fields);
    });
  }

  visitFieldFormalParameter(FieldFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      token(node.keyword, after: space);
      visit(node.type, after: space);
      token(node.thisKeyword);
      token(node.period);
      visit(node.identifier);
      visit(node.parameters);
    });
  }

  visitForEachStatement(ForEachStatement node) {
    builder.nestExpression();
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
    builder.unnest(now: false);

    _visitLoopBody(node.body);
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
        .where((param) => param is! DefaultFormalParameter)
        .toList();
    var optionalParams = node.parameters
        .where((param) => param is DefaultFormalParameter)
        .toList();

    builder.nestExpression();
    token(node.leftParenthesis);

    _metadataRules.add(new MetadataRule());

    var rule;
    if (requiredParams.isNotEmpty) {
      rule = new PositionalRule(null, 0, 0);
      _metadataRules.last.bindPositionalRule(rule);

      builder.startRule(rule);
      if (_isInLambda(node)) {
        // Don't allow splitting before the first argument (i.e. right after
        // the bare "(" in a lambda. Instead, just stuff a null chunk in there
        // to avoid confusing the arg rule.
        rule.beforeArgument(null);
      } else {
        // Split before the first argument.
        rule.beforeArgument(zeroSplit());
      }

      builder.startSpan();

      for (var param in requiredParams) {
        visit(param);

        // Write the trailing comma.
        if (param != node.parameters.last) token(param.endToken.next);

        if (param != requiredParams.last) rule.beforeArgument(split());
      }

      builder.endSpan();
      builder.endRule();
    }

    if (optionalParams.isNotEmpty) {
      var namedRule = new NamedRule(null, 0, 0);
      if (rule != null) rule.setNamedArgsRule(namedRule);

      _metadataRules.last.bindNamedRule(namedRule);

      builder.startRule(namedRule);

      // Make sure multi-line default values are indented.
      builder.startBlockArgumentNesting();

      namedRule.beforeArgument(builder.split(space: requiredParams.isNotEmpty));

      // "[" or "{" for optional parameters.
      token(node.leftDelimiter);

      for (var param in optionalParams) {
        visit(param);

        // Write the trailing comma.
        if (param != node.parameters.last) token(param.endToken.next);
        if (param != optionalParams.last) namedRule.beforeArgument(split());
      }

      builder.endBlockArgumentNesting();
      builder.endRule();

      // "]" or "}" for optional parameters.
      token(node.rightDelimiter);
    }

    _metadataRules.removeLast();

    token(node.rightParenthesis);
    builder.unnest();
  }

  visitForStatement(ForStatement node) {
    builder.nestExpression();
    token(node.forKeyword);
    space();
    token(node.leftParenthesis);

    builder.startRule();

    // The initialization clause.
    if (node.initialization != null) {
      visit(node.initialization);
    } else if (node.variables != null) {
      // Nest split variables more so they aren't at the same level
      // as the rest of the loop clauses.
      builder.nestExpression();

      // Allow the variables to stay unsplit even if the clauses split.
      builder.startRule();

      var declaration = node.variables;
      visitMetadata(declaration.metadata);
      modifier(declaration.keyword);
      visit(declaration.type, after: space);

      visitCommaSeparatedNodes(declaration.variables, between: () {
        split();
      });

      builder.endRule();
      builder.unnest();
    }

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

    token(node.rightParenthesis);
    builder.endRule();
    builder.unnest();

    _visitLoopBody(node.body);
  }

  visitFunctionDeclaration(FunctionDeclaration node) {
    _visitMemberDeclaration(node, node.functionExpression);
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
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.typedefKeyword);
      space();
      visit(node.returnType, after: space);
      visit(node.name);
      visit(node.typeParameters);
      visit(node.parameters);
    });
  }

  visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    visitParameterMetadata(node.metadata, () {
      visit(node.returnType, after: space);

      // Try to keep the function's parameters with its name.
      builder.startSpan();
      visit(node.identifier);
      visit(node.parameters);
      builder.endSpan();
    });
  }

  visitHideCombinator(HideCombinator node) {
    _visitCombinator(node.keyword, node.hiddenNames);
  }

  visitIfStatement(IfStatement node) {
    builder.nestExpression();
    token(node.ifKeyword);
    space();
    token(node.leftParenthesis);
    visit(node.condition);
    token(node.rightParenthesis);
    builder.unnest(now: false);

    visitClause(Statement clause) {
      if (clause is Block || clause is IfStatement) {
        space();
        visit(clause);
      } else {
        // Allow splitting in an expression-bodied if even though it's against
        // the style guide. Since we can't fix the code itself to follow the
        // style guide, we should at least format it as well as we can.
        builder.nestExpression(indent: 2, now: true);
        builder.startRule();

        // If there is an else clause, always split before both the then and
        // else statements.
        if (node.elseStatement != null) {
          builder.writeWhitespace(Whitespace.nestedNewline);
        } else {
          split();
        }

        visit(clause);

        builder.endRule();
        builder.unnest();
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
      visitClause(node.elseStatement);
    }
  }

  visitImplementsClause(ImplementsClause node) {
    _visitCombinator(node.implementsKeyword, node.interfaces);
  }

  visitImportDirective(ImportDirective node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
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

      builder.startRule(new CombinatorRule());
      visitNodes(node.combinators);
      builder.endRule();
    });
  }

  visitIndexExpression(IndexExpression node) {
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

    builder.startSpan();
    token(node.leftBracket);
    soloZeroSplit();
    visit(node.index);
    token(node.rightBracket);
    builder.endSpan();
  }

  visitInstanceCreationExpression(InstanceCreationExpression node) {
    builder.startSpan();
    token(node.keyword);
    space();
    builder.startSpan(Cost.constructorName);
    visit(node.constructorName);
    builder.endSpan();
    visit(node.argumentList);
    builder.endSpan();
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
    _writeStringLiteral(node.contents.lexeme, node.offset);
  }

  visitIsExpression(IsExpression node) {
    builder.startSpan();
    visit(node.expression);
    soloSplit();
    token(node.isOperator);
    token(node.notOperator);
    space();
    visit(node.type);
    builder.endSpan();
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
    visitMetadata(node.metadata);

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
    _visitMemberDeclaration(node, node);
  }

  visitMethodInvocation(MethodInvocation node) {
    // If there's no target, this is a "bare" function call like "foo(1, 2)",
    // or a section in a cascade. Handle this case specially.
    if (node.target == null) {
      // Try to keep the entire method invocation one line.
      builder.startSpan();
      builder.nestExpression();

      // This will be non-null for cascade sections.
      token(node.operator);
      token(node.methodName.token);
      visit(node.argumentList);

      builder.unnest();
      builder.endSpan();
      return;
    }

    new CallChainVisitor(this, node).visit();
  }

  visitNamedExpression(NamedExpression node) {
    visitNamedArgument(node);
  }

  visitNativeClause(NativeClause node) {
    token(node.nativeKeyword);
    space();
    visit(node.name);
  }

  visitNativeFunctionBody(NativeFunctionBody node) {
    _simpleStatement(node, () {
      builder.nestExpression(now: true);
      soloSplit();
      token(node.nativeKeyword);
      space();
      visit(node.stringLiteral);
      builder.unnest();
    });
  }

  visitNullLiteral(NullLiteral node) {
    token(node.literal);
  }

  visitParenthesizedExpression(ParenthesizedExpression node) {
    builder.nestExpression();
    token(node.leftParenthesis);
    visit(node.expression);
    builder.unnest();
    token(node.rightParenthesis);
  }

  visitPartDirective(PartDirective node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      visit(node.uri);
    });
  }

  visitPartOfDirective(PartOfDirective node) {
    visitMetadata(node.metadata);

    _simpleStatement(node, () {
      token(node.keyword);
      space();
      token(node.ofKeyword);
      space();
      visit(node.libraryName);
    });
  }

  visitPostfixExpression(PostfixExpression node) {
    visit(node.operand);
    token(node.operator);
  }

  visitPrefixedIdentifier(PrefixedIdentifier node) {
    new CallChainVisitor(this, node).visit();
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
      visit(node.propertyName);
      return;
    }

    new CallChainVisitor(this, node).visit();
  }

  visitRedirectingConstructorInvocation(RedirectingConstructorInvocation node) {
    builder.startSpan();

    token(node.thisKeyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    builder.endSpan();
  }

  visitRethrowExpression(RethrowExpression node) {
    token(node.rethrowKeyword);
  }

  visitReturnStatement(ReturnStatement node) {
    _simpleStatement(node, () {
      token(node.returnKeyword);
      visit(node.expression, before: space);
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
    visitParameterMetadata(node.metadata, () {
      modifier(node.keyword);
      visit(node.type, after: space);
      visit(node.identifier);
    });
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

    visitNodes(node.elements);
  }

  visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    builder.startSpan();

    token(node.superKeyword);
    token(node.period);
    visit(node.constructorName);
    visit(node.argumentList);

    builder.endSpan();
  }

  visitSuperExpression(SuperExpression node) {
    token(node.superKeyword);
  }

  visitSwitchCase(SwitchCase node) {
    visitNodes(node.labels, between: space, after: space);
    token(node.keyword);
    space();
    visit(node.expression);
    token(node.colon);

    builder.indent();
    // TODO(rnystrom): Allow inline cases?
    newline();

    visitNodes(node.statements, between: oneOrTwoNewlines);
    builder.unindent();
  }

  visitSwitchDefault(SwitchDefault node) {
    visitNodes(node.labels, between: space, after: space);
    token(node.keyword);
    token(node.colon);

    builder.indent();
    // TODO(rnystrom): Allow inline cases?
    newline();

    visitNodes(node.statements, between: oneOrTwoNewlines);
    builder.unindent();
  }

  visitSwitchStatement(SwitchStatement node) {
    builder.nestExpression();
    token(node.switchKeyword);
    space();
    token(node.leftParenthesis);
    soloZeroSplit();
    visit(node.expression);
    token(node.rightParenthesis);
    space();
    token(node.leftBracket);
    builder.unnest();
    builder.indent();
    newline();

    visitNodes(node.members, between: oneOrTwoNewlines, after: newline);
    token(node.rightBracket, before: () {
      builder.unindent();
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
    token(node.thisKeyword);
  }

  visitThrowExpression(ThrowExpression node) {
    token(node.throwKeyword);
    space();
    visit(node.expression);
  }

  visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    visitMetadata(node.metadata);

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
    _visitGenericList(node.leftBracket, node.rightBracket, node.arguments);
  }

  visitTypeName(TypeName node) {
    visit(node.name);
    visit(node.typeArguments);
  }

  visitTypeParameter(TypeParameter node) {
    visitParameterMetadata(node.metadata, () {
      visit(node.name);
      token(node.extendsKeyword, before: space, after: space);
      visit(node.bound);
    });
  }

  visitTypeParameterList(TypeParameterList node) {
    _metadataRules.add(new MetadataRule());

    _visitGenericList(node.leftBracket, node.rightBracket, node.typeParameters);

    _metadataRules.removeLast();
  }

  visitVariableDeclaration(VariableDeclaration node) {
    visit(node.name);
    if (node.initializer == null) return;

    _visitAssignment(node.equals, node.initializer);
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    visitMetadata(node.metadata);

    // Allow but try to avoid splitting between the type and name.
    builder.startSpan();

    modifier(node.keyword);
    visit(node.type, after: soloSplit);

    builder.endSpan();

    // Use a single rule for all of the variables. If there are multiple
    // declarations, we will try to keep them all on one line. If that isn't
    // possible, we split after *every* declaration so that each is on its own
    // line.
    builder.startRule();
    visitCommaSeparatedNodes(node.variables, between: split);
    builder.endRule();
  }

  visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    _simpleStatement(node, () {
      visit(node.variables);
    });
  }

  visitWhileStatement(WhileStatement node) {
    builder.nestExpression();
    token(node.whileKeyword);
    space();
    token(node.leftParenthesis);
    soloZeroSplit();
    visit(node.condition);
    token(node.rightParenthesis);
    builder.unnest(now: false);

    _visitLoopBody(node.body);
  }

  visitWithClause(WithClause node) {
    _visitCombinator(node.withKeyword, node.mixinTypes);
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

  /// Visit metadata annotations on directives, declarations, and members.
  ///
  /// These always force the annotations to be on the previous line.
  void visitMetadata(NodeList<Annotation> metadata) {
    visitNodes(metadata, between: newline, after: newline);
  }

  /// Visits metadata annotations on parameters and type parameters.
  ///
  /// Unlike other annotations, these are allowed to stay on the same line as
  /// the parameter.
  void visitParameterMetadata(
      NodeList<Annotation> metadata, void visitParameter()) {
    if (metadata == null || metadata.isEmpty) {
      visitParameter();
      return;
    }

    // Split before all of the annotations or none.
    builder.startLazyRule(_metadataRules.last);

    visitNodes(metadata, between: split, after: () {
      // Don't nest until right before the last metadata. Ensures we only
      // indent the parameter and not any of the metadata:
      //
      //     function(
      //         @LongAnnotation
      //         @LongAnnotation
      //             indentedParameter) {}
      builder.nestExpression(now: true);
      split();
    });
    visitParameter();

    builder.unnest();

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
  void visitNamedArgument(NamedExpression node, [NamedRule rule]) {
    builder.nestExpression();
    builder.startSpan();
    visit(node.name);

    // Don't allow a split between a name and a collection. Instead, we want
    // the collection itself to split, or to split before the argument.
    if (node.expression is ListLiteral || node.expression is MapLiteral) {
      space();
    } else {
      var split = soloSplit();
      if (rule != null) split.imply(rule);
    }

    visit(node.expression);
    builder.endSpan();
    builder.unnest();
  }

  /// Visits the `=` and the following expression in any place where an `=`
  /// appears:
  ///
  /// * Assignment
  /// * Variable declaration
  /// * Constructor initialization
  void _visitAssignment(Token equalsOperator, Expression rightHandSide) {
    space();
    token(equalsOperator);
    soloSplit(_assignmentCost(rightHandSide));
    builder.startSpan();
    visit(rightHandSide);
    builder.endSpan();
  }

  /// Visits a type parameter or type argument list.
  void _visitGenericList(
      Token leftBracket, Token rightBracket, List<AstNode> nodes) {
    var rule = new TypeArgumentRule();
    builder.startRule(rule);
    builder.startSpan();
    builder.nestExpression();

    token(leftBracket);
    rule.beforeArgument(zeroSplit());

    for (var node in nodes) {
      visit(node);

      // Write the trailing comma.
      if (node != nodes.last) {
        token(node.endToken.next);
        rule.beforeArgument(split());
      }
    }

    token(rightBracket);

    builder.unnest();
    builder.endSpan();
    builder.endRule();
  }

  /// Visits a top-level function or method declaration.
  ///
  /// The two AST node types are very similar but, alas, share no common
  /// interface type in analyzer, hence the dynamic typing.
  void _visitMemberDeclaration(
      /* FunctionDeclaration|MethodDeclaration */ node,
      /* FunctionExpression|MethodDeclaration */ function) {
    visitMetadata(node.metadata as NodeList<Annotation>);

    // Nest the signature in case we have to split between the return type and
    // name.
    builder.nestExpression();
    builder.startSpan();
    modifier(node.externalKeyword);
    if (node is MethodDeclaration) modifier(node.modifierKeyword);
    visit(node.returnType, after: soloSplit);
    modifier(node.propertyKeyword);
    if (node is MethodDeclaration) modifier(node.operatorKeyword);
    visit(node.name);
    builder.endSpan();

    // If the body is a block, we need to exit any nesting first. If it's an
    // expression, we want to wrap the nesting around that so that the body
    // gets nested farther.
    if (function.body is! ExpressionFunctionBody) builder.unnest();

    _visitBody(function.parameters, function.body);

    if (function.body is ExpressionFunctionBody) builder.unnest();
  }

  /// Visit the given function [parameters] followed by its [body], printing a
  /// space before it if it's not empty.
  ///
  /// If [afterParameters] is provided, it is invoked between the parameters
  /// and body. (It's used for constructor initialization lists.)
  void _visitBody(FormalParameterList parameters, FunctionBody body,
      [afterParameters()]) {
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
      builder.startLazyRule(new Rule(Cost.arrow));
    }

    if (parameters != null) {
      builder.nestExpression();
      visit(parameters);
      builder.unnest();

      if (afterParameters != null) afterParameters();
    }

    visit(body);

    if (body is ExpressionFunctionBody) builder.unnest();
  }

  /// Visits the body statement of a `for` or `for in` loop.
  void _visitLoopBody(Statement body) {
    if (body is EmptyStatement) {
      // No space before the ";".
      visit(body);
    } else if (body is Block) {
      space();
      visit(body);
    } else {
      // Allow splitting in an expression-bodied for even though it's against
      // the style guide. Since we can't fix the code itself to follow the
      // style guide, we should at least format it as well as we can.
      builder.nestExpression(indent: 2, now: true);
      builder.startRule();

      split();
      visit(body);

      builder.endRule();
      builder.unnest();
    }
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
      Iterable<AstNode> elements, Token rightBracket,
      [int cost]) {
    modifier(node.constKeyword);
    visit(node.typeArguments);

    // Don't allow splitting in an empty collection.
    if (elements.isEmpty && rightBracket.precedingComments == null) {
      token(leftBracket);
      token(rightBracket);
      return;
    }

    // Force all of the surrounding collections to split.
    for (var i = 0; i < _collectionSplits.length; i++) {
      _collectionSplits[i] = true;
    }

    // Add this collection to the stack.
    _collectionSplits.add(false);

    _startLiteralBody(leftBracket);

    // If a collection contains a line comment, we assume it's a big complex
    // blob of data with some documented structure. In that case, the user
    // probably broke the elements into lines deliberately, so preserve those.
    var preserveNewlines = _containsLineComments(elements, rightBracket);

    var rule;
    var lineRule;
    if (preserveNewlines) {
      // Newlines are significant, so we'll explicitly write those. Elements
      // on the same line all share an argument-list-like rule that allows
      // splitting between zero, one, or all of them. This is faster in long
      // lists than using individual splits after each element.
      lineRule = new TypeArgumentRule();
      builder.startLazyRule(lineRule);
    } else {
      // Newlines aren't significant, so use a hard rule to split the elements.
      // The parent chunk of the collection will handle the unsplit case, so
      // this only comes into play when the collection is split.
      rule = new Rule.hard();
      builder.startRule(rule);
    }

    for (var element in elements) {
      if (element != elements.first) {
        if (preserveNewlines) {
          // See if the next element is on the next line.
          if (_endLine(element.beginToken.previous) !=
              _startLine(element.beginToken)) {
            oneOrTwoNewlines();

            // Start a new rule for the new line.
            builder.endRule();
            lineRule = new TypeArgumentRule();
            builder.startLazyRule(lineRule);
          } else {
            lineRule.beforeArgument(split());
          }
        } else {
          builder.split(nest: false, space: true);
        }
      }

      builder.nestExpression();
      visit(element);

      // The comma after the element.
      if (element.endToken.next.lexeme == ",") token(element.endToken.next);

      builder.unnest();
    }

    builder.endRule();

    // If there is a collection inside this one, it forces this one to split.
    var force = _collectionSplits.removeLast();

    _endLiteralBody(rightBracket, ignoredRule: rule, forceSplit: force);
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
    if (rightHandSide is MapLiteral) return Cost.assignBlock;
    if (rightHandSide is CascadeExpression) return Cost.assignBlock;

    return Cost.assign;
  }

  /// Returns `true` if the collection withs [elements] delimited by
  /// [rightBracket] contains any line comments.
  ///
  /// This only looks for comments at the element boundary. Comments within an
  /// element are ignored.
  bool _containsLineComments(Iterable<AstNode> elements, Token rightBracket) {
    hasLineCommentBefore(token) {
      var comment = token.precedingComments;
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

  /// Begins writing a literal body: a collection or block-bodied function
  /// expression.
  ///
  /// Writes the delimiter and then creates the [Rule] that handles splitting
  /// the body.
  void _startLiteralBody(Token leftBracket) {
    token(leftBracket);

    // See if this literal is associated with an argument list that wants to
    // handle splitting and indenting it. If not, we'll use a default rule.
    var rule;
    var argumentChunk;
    if (_collectionArgumentLists.containsKey(leftBracket)) {
      var argumentList = _collectionArgumentLists[leftBracket];
      rule = argumentList.collectionRule;
      argumentChunk = argumentList.previousSplit;
    }

    // Create a rule for whether or not to split the block contents.
    builder.startRule(rule);

    // Process the collection contents as a separate set of chunks.
    builder = builder.startBlock(argumentChunk);
  }

  /// Ends the literal body started by a call to [_startLiteralBody()].
  ///
  /// If [forceSplit] is `true`, forces the body to split. If [ignoredRule] is
  /// given, ignores that rule inside the body when determining if it should
  /// split.
  void _endLiteralBody(Token rightBracket,
      {Rule ignoredRule, bool forceSplit}) {
    if (forceSplit == null) forceSplit = false;

    // Put comments before the closing delimiter inside the block.
    var hasLeadingNewline = writePrecedingCommentsAndNewlines(rightBracket);

    builder = builder.endBlock(ignoredRule,
        forceSplit: hasLeadingNewline || forceSplit);

    builder.endRule();

    // Now write the delimiter itself.
    _writeText(rightBracket.lexeme, rightBracket.offset);
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
  void _simpleStatement(AstNode node, body()) {
    builder.nestExpression();
    body();

    // TODO(rnystrom): Can the analyzer move "semicolon" to some shared base
    // type?
    token((node as dynamic).semicolon);
    builder.unnest();
  }

  /// Marks the collection literal that starts with [leftBracket] as being
  /// controlled by [argumentList].
  ///
  /// When the collection is visited, [argumentList] will determine the
  /// indentation and splitting rule for the collection.
  void beforeCollection(Token leftBracket, ArgumentSublist argumentList) {
    _collectionArgumentLists[leftBracket] = argumentList;
  }

  /// Writes an bracket-delimited body and handles indenting and starting the
  /// rule used to split the contents.
  ///
  /// If [space] is `true`, then the contents and delimiters will have a space
  /// between then when unsplit.
  void _writeBody(Token leftBracket, Token rightBracket,
      {bool space: false, body()}) {
    token(leftBracket);

    // Indent the body.
    builder.indent();

    // Split after the bracket.
    builder.startRule();
    builder.split(isDouble: false, nest: false, space: space);

    body();

    token(rightBracket, before: () {
      // Split before the closing bracket character.
      builder.unindent();
      builder.split(nest: false, space: space);
    });

    builder.endRule();
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
      builder.writeWhitespace(Whitespace.newlineFlushLeft);
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
    builder.writeWhitespace(Whitespace.space);
  }

  /// Emit a single mandatory newline.
  void newline() {
    builder.writeWhitespace(Whitespace.newline);
  }

  /// Emit a two mandatory newlines.
  void twoNewlines() {
    builder.writeWhitespace(Whitespace.twoNewlines);
  }

  /// Allow either a single split or newline to be emitted before the next
  /// non-whitespace token based on whether a newline exists in the source
  /// between the last token and the next one.
  void splitOrNewline() {
    builder.writeWhitespace(Whitespace.splitOrNewline);
  }

  /// Allow either one or two newlines to be emitted before the next
  /// non-whitespace token based on whether more than one newline exists in the
  /// source between the last token and the next one.
  void oneOrTwoNewlines() {
    builder.writeWhitespace(Whitespace.oneOrTwoNewlines);
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
  Rule soloSplit([int cost]) {
    var rule = new Rule(cost);
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
  void token(Token token, {before(), after()}) {
    if (token == null) return;

    writePrecedingCommentsAndNewlines(token);

    if (before != null) before();

    _writeText(token.lexeme, token.offset);

    if (after != null) after();
  }

  /// Writes all formatted whitespace and comments that appear before [token].
  bool writePrecedingCommentsAndNewlines(Token token) {
    var comment = token.precedingComments;

    // For performance, avoid calculating newlines between tokens unless
    // actually needed.
    if (comment == null) {
      if (builder.needsToPreserveNewlines) {
        builder.preserveNewlines(_startLine(token) - _endLine(token.previous));
      }

      return false;
    }

    var previousLine = _endLine(token.previous);

    // Corner case! The analyzer includes the "\n" in the script tag's lexeme,
    // which means it appears to be one line later than it is. That causes a
    // comment following it to appear to be on the same line. Fix that here by
    // correcting the script tag's line.
    if (token.previous.type == TokenType.SCRIPT_TAG) previousLine--;

    var tokenLine = _startLine(token);

    var comments = <SourceComment>[];
    while (comment != null) {
      var commentLine = _startLine(comment);

      // Don't preserve newlines at the top of the file.
      if (comment == token.precedingComments &&
          token.previous.type == TokenType.EOF) {
        previousLine = commentLine;
      }

      var text = comment.toString().trim();
      var linesBefore = commentLine - previousLine;
      var flushLeft = _startColumn(comment) == 1;

      if (text.startsWith("///") && !text.startsWith("////")) {
        // Line doc comments are always indented even if they were flush left.
        flushLeft = false;

        // Always add a blank line (if possible) before a doc comment block.
        if (comment == token.precedingComments) linesBefore = 2;
      }

      var sourceComment = new SourceComment(text, linesBefore,
          isLineComment: comment.type == TokenType.SINGLE_LINE_COMMENT,
          flushLeft: flushLeft);

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

  /// Write [text] to the current chunk, given that it starts at [offset] in
  /// the original source.
  ///
  /// Also outputs the selection endpoints if needed.
  void _writeText(String text, int offset) {
    builder.write(text);

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
