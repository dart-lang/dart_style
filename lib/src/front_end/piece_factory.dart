// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/adjacent.dart';
import '../piece/assign.dart';
import '../piece/clause.dart';
import '../piece/control_flow.dart';
import '../piece/for.dart';
import '../piece/if_case.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/sequence.dart';
import '../piece/type.dart';
import '../piece/variable.dart';
import 'ast_node_visitor.dart';
import 'chain_builder.dart';
import 'comment_writer.dart';
import 'delimited_list_builder.dart';
import 'piece_writer.dart';
import 'sequence_builder.dart';

/// Record type for a destructured binary operator-like syntactic construct.
typedef BinaryOperation = (AstNode left, Token operator, AstNode right);

/// The kind of syntax surrounding a node when being converted to a [Piece], if
/// that surrounding syntax may affect how the child node is formatted.
///
/// For example, binary operators indent their subsequent operands in most
/// places:
///
///     function(
///       operand +
///           operand,
///     );
///
/// But not when they appear on the right-hand side of an assignment or
/// assignment-like structure:
///
///     variable =
///         operand +
///         operand;
///
/// To handle this, when the code for a node recursively visits a child, it can
/// pass in a context describing itself, which the child can then access to
/// decide how it should be formatted.
enum NodeContext {
  /// No specified context.
  none,

  /// The child is the right-hand side of an assignment-like form.
  ///
  /// This includes assignments, variable declarations, named arguments, map
  /// entries, and `=>` function bodies.
  assignment,

  /// The child is the target of a cascade expression.
  cascadeTarget,

  /// The child is the then or else operand of a conditional expression.
  conditionalBranch,

  /// The child is a variable declaration in a for loop.
  forLoopVariable,

  /// The child is a string interpolation inside a multiline string.
  multilineStringInterpolation,

  /// The child is the outermost pattern in a switch expression case.
  switchExpressionCase
}

/// Utility methods for creating pieces that share formatting logic across
/// multiple parts of the language.
///
/// Many AST nodes are structurally similar and receive similar formatting. For
/// example, imports and exports are mostly the same, with exports a subset of
/// imports. Likewise, assert statements are formatted like function calls and
/// argument lists.
///
/// This mixin defines functions that represent a general construct that is
/// formatted a certain way. The function builds up an appropriate set of
/// [Piece]s given the various AST subcomponents passed in as parameters. The
/// main [AstNodeVisitor] class then calls those for all of the AST nodes that
/// should receive that similar formatting.
///
/// These are all void functions because they generally push their result into
/// the [PieceWriter].
///
/// Naming these functions can be hard. For example, there isn't an obvious
/// word for "import or export directive" or "named thing with argument list".
/// To avoid that, we pick one concrete construct formatted by the function,
/// usually the most common, and name it after that, as in [createImport()].
mixin PieceFactory {
  /// A stack that handles forcing nested list, map, and set literals to split.
  ///
  /// Each entry corresponds to a collection currently being visited and the
  /// value is whether or not it should be forced to split because an inner
  /// collection was found inside it.
  ///
  /// When we begin a collection, we set all of the existing elements to `true`
  /// then push `false` for the new collection. When done visiting the elements,
  /// we pop the last value, If it's `true`, we know we visited a nested
  /// collection so we force this one to split.
  final List<bool> _collectionSplits = [];

  PieceWriter get pieces;

  CommentWriter get comments;

  NodeContext get parentContext;

  void visitNode(AstNode node, NodeContext context);

  /// Writes a [ListPiece] for an argument list.
  void writeArgumentList(
      Token leftBracket, List<AstNode> elements, Token rightBracket) {
    writeList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: const ListStyle(allowBlockElement: true));
  }

  /// Writes a bracket-delimited block or declaration body.
  ///
  /// If [forceSplit] is `true`, then the block will split even if empty. This
  /// is used, for example, with empty blocks in `if` statements followed by
  /// `else` clauses:
  ///
  ///     if (condition) {
  ///     } else {}
  void writeBody(Token leftBracket, List<AstNode> contents, Token rightBracket,
      {bool forceSplit = false}) {
    // If the body is completely empty, write the brackets directly inline so
    // that we create fewer pieces.
    if (!forceSplit && !contents.canSplit(rightBracket)) {
      pieces.token(leftBracket);
      pieces.token(rightBracket);
      return;
    }

    var sequence = SequenceBuilder(this);
    sequence.leftBracket(leftBracket);

    for (var node in contents) {
      sequence.visit(node);

      // If the node has a non-empty braced body, then require a blank line
      // between it and the next node.
      if (node.hasNonEmptyBody) sequence.addBlank();
    }

    sequence.rightBracket(rightBracket);
    pieces.add(sequence.build(forceSplit: forceSplit));
  }

  /// Writes a [SequencePiece] for a given [Block].
  ///
  /// If [forceSplit] is `true`, then the block will split even if empty. This
  /// is used, for example, with empty blocks in `if` statements followed by
  /// `else` clauses:
  ///
  ///     if (condition) {
  ///     } else {}
  void writeBlock(Block block, {bool forceSplit = false}) {
    writeBody(block.leftBracket, block.statements, block.rightBracket,
        forceSplit: forceSplit);
  }

  /// Writes a piece for a `break` or `continue` statement.
  void writeBreak(Token keyword, SimpleIdentifier? label, Token semicolon) {
    pieces.token(keyword);
    pieces.visit(label, spaceBefore: true);
    pieces.token(semicolon);
  }

  void writeChain(Expression node) {
    pieces.add(ChainBuilder(this, node)
        .build(isCascadeTarget: parentContext == NodeContext.cascadeTarget));
  }

  /// Writes a [ListPiece] for a collection literal or pattern.
  ///
  /// If [splitOnNestedCollection] is `true`, then this collection is forced to
  /// split if it contains any non-empty collections where
  /// [splitOnNestedCollection] is also `true`, even if the collection would
  /// otherwise not need to split. This is `true` for list, map, and set
  /// expressions because they are often used for composite data structures and
  /// they're easier to read if they don't get packed too densely:
  ///
  ///     // Prefer:
  ///     data = {
  ///       'a': [1, 2, 3],
  ///       'b': [
  ///         4,
  ///         [5],
  ///         6,
  ///       ]
  ///       'c': [7, 8],
  ///     };
  ///
  ///     // Over:
  ///     data = {'a': [1, 2, 3], 'b': [4, [5], 6] 'c': [7, 8]};
  ///
  /// We don't do this for record expressions because those are not unbounded
  /// in size and generally represent aggregations of data where the fields are
  /// more "closely" bundled together. Record expressions are sort of like
  /// constructor invocations for an anonymous constructor.
  ///
  /// We don't do this for patterns because it's better to fit a pattern on a
  /// single line when possible for parallel cases in switches.
  ///
  /// If [preserveNewlines] is `true`, then any newlines or lack of newlines
  /// between pairs of elements in the input are preserved in the output. This
  /// is used for collection literals that contain line comments to preserve
  /// the author's deliberate structuring, as in:
  ///
  ///     matrix = [
  ///       // X, Y, Z:
  ///       1, 2, 3,
  ///       4, 5, 6,
  ///       7, 8, 9,
  ///     ];
  void writeCollection(
    Token leftBracket,
    List<AstNode> elements,
    Token rightBracket, {
    Token? constKeyword,
    TypeArgumentList? typeArguments,
    ListStyle style = const ListStyle(),
    bool splitOnNestedCollection = false,
    bool preserveNewlines = false,
  }) {
    pieces.modifier(constKeyword);
    pieces.visit(typeArguments);

    // If the list is completely empty, write the brackets inline so we create
    // fewer pieces.
    if (!elements.canSplit(rightBracket)) {
      pieces.token(leftBracket);
      pieces.token(rightBracket);
      return;
    }

    if (splitOnNestedCollection) {
      // If this collection isn't empty, force all of the surrounding
      // collections to split if they care to.
      if (elements.isNotEmpty) {
        _collectionSplits.fillRange(0, _collectionSplits.length, true);
      }

      // Add this collection to the stack.
      _collectionSplits.add(false);
    }

    var collection = pieces.build(() {
      writeList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: style,
        preserveNewlines: preserveNewlines,
      );
    });

    // If there is a collection inside this one, force this one to split.
    if (splitOnNestedCollection) {
      if (_collectionSplits.removeLast()) collection.pin(State.split);
    }

    pieces.add(collection);
  }

  /// Creates a comma-separated [ListPiece] for [nodes].
  Piece createCommaSeparated(Iterable<AstNode> nodes) {
    var builder =
        DelimitedListBuilder(this, const ListStyle(commas: Commas.nonTrailing));
    nodes.forEach(builder.visit);
    return builder.build();
  }

  /// Writes the leading keyword and parenthesized expression at the beginning
  /// of an `if`, `while`, or `switch` expression or statement.
  void writeControlFlowStart(Token keyword, Token leftParenthesis,
      Expression value, Token rightParenthesis) {
    pieces.token(keyword);
    pieces.space();
    pieces.token(leftParenthesis);
    pieces.visit(value);
    pieces.token(rightParenthesis);
  }

  /// Writes a dotted or qualified identifier.
  void writeDotted(NodeList<SimpleIdentifier> components) {
    for (var component in components) {
      // Write the preceding ".".
      if (component != components.first) {
        pieces.token(component.beginToken.previous!);
      }

      pieces.visit(component);
    }
  }

  /// Creates a [Piece] for an enum constant.
  ///
  /// If the constant is in an enum declaration that also declares members, then
  /// [semicolon] should be the `;` token before the members, and
  /// [isLastConstant] is `true` if [node] is the last constant before the
  /// members.
  Piece createEnumConstant(EnumConstantDeclaration node,
      {bool isLastConstant = false, Token? semicolon}) {
    return pieces.build(metadata: node.metadata, () {
      pieces.token(node.name);
      if (node.arguments case var arguments?) {
        pieces.visit(arguments.typeArguments);
        pieces.visit(arguments.constructorSelector);
        pieces.visit(arguments.argumentList);
      }

      if (semicolon != null) {
        if (!isLastConstant) {
          pieces.token(node.commaAfter);
        } else {
          // Discard the trailing comma if there is one since there is a
          // semicolon to use as the separator, but preserve any comments before
          // the discarded comma.
          pieces.add(
              pieces.tokenPiece(discardedToken: node.commaAfter, semicolon));
        }
      }
    });
  }

  /// Writes a piece for a for statement or element.
  void writeFor(
      {required Token? awaitKeyword,
      required Token forKeyword,
      required Token leftParenthesis,
      required ForLoopParts forLoopParts,
      required Token rightParenthesis,
      required AstNode body,
      required bool hasBlockBody,
      bool forceSplitBody = false}) {
    var forKeywordPiece = pieces.build(() {
      pieces.modifier(awaitKeyword);
      pieces.token(forKeyword);
    });

    Piece forPartsPiece;
    switch (forLoopParts) {
      // Edge case: A totally empty for loop is formatted just as `(;;)` with
      // no splits or spaces anywhere.
      case ForPartsWithExpression(
            initialization: null,
            leftSeparator: Token(precedingComments: null),
            condition: null,
            rightSeparator: Token(precedingComments: null),
            updaters: NodeList(isEmpty: true),
          )
          when rightParenthesis.precedingComments == null:
        forPartsPiece = pieces.build(() {
          pieces.token(leftParenthesis);
          pieces.token(forLoopParts.leftSeparator);
          pieces.token(forLoopParts.rightSeparator);
          pieces.token(rightParenthesis);
        });

      case ForParts forParts &&
            ForPartsWithDeclarations(variables: AstNode? initializer):
      case ForParts forParts &&
            ForPartsWithExpression(initialization: AstNode? initializer):
      case ForParts forParts &&
            ForPartsWithPattern(variables: AstNode? initializer):
        // In a C-style for loop, treat the for loop parts like an argument list
        // where each clause is a separate argument. This means that when they
        // split, they split like:
        //
        //     for (
        //       initializerClause;
        //       conditionClause;
        //       incrementClause
        //     ) {
        //       body;
        //     }
        var partsList =
            DelimitedListBuilder(this, const ListStyle(commas: Commas.none));
        partsList.leftBracket(leftParenthesis);

        // The initializer clause.
        if (initializer != null) {
          partsList.addCommentsBefore(initializer.beginToken);
          partsList.add(pieces.build(() {
            pieces.visit(initializer, context: NodeContext.forLoopVariable);
            pieces.token(forParts.leftSeparator);
          }));
        } else {
          // No initializer, so look at the comments before `;`.
          partsList.addCommentsBefore(forParts.leftSeparator);
          partsList.add(tokenPiece(forParts.leftSeparator));
        }

        // The condition clause.
        if (forParts.condition case var conditionExpression?) {
          partsList.addCommentsBefore(conditionExpression.beginToken);
          partsList.add(pieces.build(() {
            pieces.visit(conditionExpression);
            pieces.token(forParts.rightSeparator);
          }));
        } else {
          partsList.addCommentsBefore(forParts.rightSeparator);
          partsList.add(tokenPiece(forParts.rightSeparator));
        }

        // The update clauses.
        if (forParts.updaters.isNotEmpty) {
          partsList.addCommentsBefore(forParts.updaters.first.beginToken);
          partsList.add(createCommaSeparated(forParts.updaters));
        }

        partsList.rightBracket(rightParenthesis);
        forPartsPiece = partsList.build();

      case ForEachParts forEachParts &&
            ForEachPartsWithDeclaration(loopVariable: AstNode variable):
      case ForEachParts forEachParts &&
            ForEachPartsWithIdentifier(identifier: AstNode variable):
        // If a for-in loop, treat the for parts like an assignment, so they
        // split like:
        //
        //     for (var variable in [
        //       initializer,
        //     ]) {
        //       body;
        //     }
        // TODO(tall): Passing `canBlockSplitLeft: true` allows output like:
        //
        //     // 1
        //     for (variable in longExpression +
        //         thatWraps) {
        //       ...
        //     }
        //
        // Versus the split in the initializer forcing a split before `in` too:
        //
        //     // 2
        //     for (variable
        //         in longExpression +
        //             thatWraps) {
        //       ...
        //     }
        //
        // This is also allowed:
        //
        //     // 3
        //     for (variable
        //         in longExpression + thatWraps) {
        //       ...
        //     }
        //
        // Currently, the formatter prefers 1 over 3. We may want to revisit
        // that and prefer 3 instead. Or perhaps we shouldn't pass
        // `canBlockSplitLeft: true` and force the `in` to split if the
        // initializer does. That would be consistent with how we handle
        // splitting before `case` when the pattern has a newline in an if-case
        // statement or element.
        forPartsPiece = pieces.build(() {
          pieces.token(leftParenthesis);
          writeForIn(variable, forEachParts.inKeyword, forEachParts.iterable);
          pieces.token(rightParenthesis);
        });

      case ForEachParts forEachParts &&
            ForEachPartsWithPattern(:var keyword, :var metadata, :var pattern):
        forPartsPiece = pieces.build(() {
          pieces.token(leftParenthesis);

          // Use a nested piece so that the metadata precedes the keyword and
          // not the `(`.
          pieces.withMetadata(metadata, inlineMetadata: true, () {
            pieces.token(keyword);
            pieces.space();

            writeForIn(pattern, forEachParts.inKeyword, forEachParts.iterable);
          });
          pieces.token(rightParenthesis);
        });
    }

    var bodyPiece = nodePiece(body);

    // If there is metadata before the for loop variable or pattern, then make
    // sure that the entire contents of the for loop parts are indented so that
    // the annotations are indented.
    var indentHeader = switch (forLoopParts) {
      ForEachPartsWithDeclaration(:var loopVariable) =>
        loopVariable.metadata.isNotEmpty,
      ForEachPartsWithPattern(:var metadata) => metadata.isNotEmpty,
      _ => false,
    };

    if (hasBlockBody) {
      pieces
          .add(ForPiece(forKeywordPiece, forPartsPiece, indent: indentHeader));
      pieces.space();
      pieces.add(bodyPiece);
    } else {
      var forPiece = ControlFlowPiece();
      forPiece.add(
          ForPiece(forKeywordPiece, forPartsPiece, indent: indentHeader),
          bodyPiece,
          isBlock: false);

      if (forceSplitBody) forPiece.pin(State.split);
      pieces.add(forPiece);
    }
  }

  /// Writes a normal (not function-typed) formal parameter with a name and/or
  /// type annotation.
  ///
  /// If [mutableKeyword] is given, it should be the `var` or `final` keyword.
  /// If [fieldKeyword] and [period] are given, the former should be the `this`
  /// or `super` keyword for an initializing formal or super parameter.
  void writeFormalParameter(
      FormalParameter node, TypeAnnotation? type, Token? name,
      {Token? mutableKeyword, Token? fieldKeyword, Token? period}) {
    // If the parameter has a default value, the parameter node will be wrapped
    // in a DefaultFormalParameter node containing the default.
    (Token separator, Expression value)? defaultValueRecord;
    if (node.parent
        case DefaultFormalParameter(:var separator?, :var defaultValue?)) {
      defaultValueRecord = (separator, defaultValue);
    }

    writeParameter(
        metadata: node.metadata,
        modifiers: [
          node.requiredKeyword,
          node.covariantKeyword,
          mutableKeyword,
        ],
        type,
        fieldKeyword: fieldKeyword,
        period: period,
        name,
        defaultValue: defaultValueRecord);
  }

  /// Writes a function, method, getter, or setter declaration.
  ///
  /// If [modifierKeyword] is given, it should be the `static` or `abstract`
  /// modifier on a method declaration. If [operatorKeyword] is given, it
  /// should be the `operator` keyword on an operator declaration. If
  /// [propertyKeyword] is given, it should be the `get` or `set` keyword on a
  /// getter or setter declaration.
  void writeFunction(
      {List<Annotation> metadata = const [],
      List<Token?> modifiers = const [],
      TypeAnnotation? returnType,
      Token? operatorKeyword,
      Token? propertyKeyword,
      Token? name,
      TypeParameterList? typeParameters,
      FormalParameterList? parameters,
      required FunctionBody body}) {
    // Create a piece to attach metadata to the function.
    pieces.withMetadata(metadata, () {
      writeFunctionAndReturnType(modifiers, returnType, () {
        // If there's no return type, attach modifiers to the signature.
        if (returnType == null) {
          for (var keyword in modifiers) {
            pieces.modifier(keyword);
          }
        }

        pieces.modifier(operatorKeyword);
        pieces.modifier(propertyKeyword);
        pieces.token(name);
        pieces.visit(typeParameters);
        pieces.visit(parameters);
        pieces.visit(body);
      });
    });
  }

  /// Writes a return type followed by either a function signature (when writing
  /// a function type annotation or function-typed formal) or a signature and a
  /// body (when writing a function declaration).
  ///
  /// The [writeFunction] callback should write the function's signature and
  /// body if there is one.
  ///
  /// If there is no return type, invokes [writeFunction] directly and returns.
  /// Otherwise, writes the return type and function and wraps them in a piece
  /// to allow splitting after the return type.
  void writeFunctionAndReturnType(List<Token?> modifiers,
      TypeAnnotation? returnType, void Function() writeFunction) {
    if (returnType == null) {
      writeFunction();
      return;
    }

    var returnTypePiece = pieces.build(() {
      for (var keyword in modifiers) {
        pieces.modifier(keyword);
      }

      pieces.visit(returnType);
    });

    var signature = pieces.build(() {
      writeFunction();
    });

    pieces.add(VariablePiece(returnTypePiece, [signature], hasType: true));
  }

  /// If [parameter] has a [defaultValue] then writes a piece for the parameter
  /// followed by that default value.
  ///
  /// Otherwise, just writes [parameter].
  void writeDefaultValue(
      Piece parameter, (Token separator, Expression value)? defaultValue) {
    if (defaultValue == null) {
      pieces.add(parameter);
      return;
    }

    var (separator, value) = defaultValue;
    var operatorPiece = pieces.build(() {
      if (separator.type == TokenType.EQ) pieces.space();
      pieces.token(separator);
      if (separator.type != TokenType.EQ) pieces.space();
    });

    var valuePiece = nodePiece(value, context: NodeContext.assignment);

    pieces.add(AssignPiece(
        left: parameter,
        operatorPiece,
        valuePiece,
        canBlockSplitRight: value.canBlockSplit));
  }

  /// Writes a function type or function-typed formal.
  ///
  /// If creating a piece for a function-typed formal, then [parameter] is the
  /// formal parameter. If there is a default value, then [defaultValue] is
  /// the `=` or `:` separator followed by the constant expression.
  ///
  /// If this is a function-typed initializing formal (`this.foo()`), then
  /// [fieldKeyword] is `this` and [period] is the `.`. Likewise, for a
  /// function-typed super parameter, [fieldKeyword] is `super`.
  void writeFunctionType(
      TypeAnnotation? returnType,
      Token functionKeywordOrName,
      TypeParameterList? typeParameters,
      FormalParameterList parameters,
      Token? question,
      {FormalParameter? parameter,
      Token? fieldKeyword,
      Token? period}) {
    var metadata = parameter?.metadata ?? const <Annotation>[];
    pieces.withMetadata(metadata, inlineMetadata: true, () {
      void write() {
        // If there's no return type, attach the parameter modifiers to the
        // signature.
        if (parameter != null && returnType == null) {
          pieces.modifier(parameter.requiredKeyword);
          pieces.modifier(parameter.covariantKeyword);
        }

        pieces.token(fieldKeyword);
        pieces.token(period);
        pieces.token(functionKeywordOrName);
        pieces.visit(typeParameters);
        pieces.visit(parameters);
        pieces.token(question);
      }

      var returnTypeModifiers = parameter != null
          ? [parameter.requiredKeyword, parameter.covariantKeyword]
          : const <Token?>[];

      // TODO(rnystrom): It would be good if the AssignPiece created for the
      // default value could treat the parameter list on the left-hand side as
      // block-splittable. But since it's a FunctionPiece and not directly a
      // ListPiece, AssignPiece doesn't support block-splitting it. If #1466 is
      // fixed, that may enable us to handle block-splitting here too. In
      // practice, it doesn't really matter since function-typed formals are
      // deprecated, default values on function-typed parameters are rare, and
      // when both occur, they rarely split.
      // If the type is a function-typed parameter with a default value, then
      // grab the default value from the parent node and attach it to the
      // function.
      if (parameter?.parent
          case DefaultFormalParameter(:var separator?, :var defaultValue?)) {
        var function = pieces.build(() {
          writeFunctionAndReturnType(returnTypeModifiers, returnType, write);
        });

        writeDefaultValue(function, (separator, defaultValue));
      } else {
        writeFunctionAndReturnType(returnTypeModifiers, returnType, write);
      }
    });
  }

  /// Writes a piece for the header -- everything from the `if` keyword to the
  /// closing `)` -- of an if statement, if element, if-case statement, or
  /// if-case element.
  void writeIfCondition(Token ifKeyword, Token leftParenthesis,
      Expression expression, CaseClause? caseClause, Token rightParenthesis) {
    pieces.token(ifKeyword);
    pieces.space();
    pieces.token(leftParenthesis);

    if (caseClause != null) {
      var expressionPiece = nodePiece(expression);

      var casePiece = pieces.build(() {
        pieces.token(caseClause.caseKeyword);
        pieces.space();
        pieces.visit(caseClause.guardedPattern.pattern);
      });

      var guardPiece = optionalNodePiece(caseClause.guardedPattern.whenClause);

      pieces.add(IfCasePiece(expressionPiece, casePiece, guardPiece,
          canBlockSplitPattern:
              caseClause.guardedPattern.pattern.canBlockSplit));
    } else {
      pieces.visit(expression);
    }

    pieces.token(rightParenthesis);
  }

  /// Writes a [TryPiece] for try statement.
  void writeTry(TryStatement tryStatement) {
    pieces.token(tryStatement.tryKeyword);
    pieces.space();
    writeBlock(tryStatement.body);

    for (var i = 0; i < tryStatement.catchClauses.length; i++) {
      var catchClause = tryStatement.catchClauses[i];

      pieces.space();
      if (catchClause.onKeyword case var onKeyword?) {
        pieces.token(onKeyword, spaceAfter: true);
        pieces.visit(catchClause.exceptionType);
      }

      if (catchClause.onKeyword != null && catchClause.catchKeyword != null) {
        pieces.space();
      }

      if (catchClause.catchKeyword case var catchKeyword?) {
        pieces.token(catchKeyword);
        pieces.space();

        var parameters = DelimitedListBuilder(this);
        parameters.leftBracket(catchClause.leftParenthesis!);
        if (catchClause.exceptionParameter case var exceptionParameter?) {
          parameters.visit(exceptionParameter);
        }
        if (catchClause.stackTraceParameter case var stackTraceParameter?) {
          parameters.visit(stackTraceParameter);
        }
        parameters.rightBracket(catchClause.rightParenthesis!);
        pieces.add(parameters.build());
      }

      pieces.space();

      // Edge case: When there's another catch/on/finally after this one, we
      // want to force the block to split even if it's empty.
      //
      //     try {
      //       ..
      //     } on Foo {
      //     } finally Bar {
      //       body;
      //     }
      var forceSplit = i < tryStatement.catchClauses.length - 1 ||
          tryStatement.finallyBlock != null;
      writeBlock(catchClause.body, forceSplit: forceSplit);
    }

    if (tryStatement.finallyBlock case var finallyBlock?) {
      pieces.space();
      pieces.token(tryStatement.finallyKeyword!);
      pieces.space();
      writeBlock(finallyBlock);
    }
  }

  /// Writes an [ImportPiece] for an import or export directive.
  void writeImport(NamespaceDirective directive, Token keyword,
      {Token? deferredKeyword, Token? asKeyword, SimpleIdentifier? prefix}) {
    pieces.withMetadata(directive.metadata, () {
      if (directive.configurations.isEmpty && asKeyword == null) {
        // If there are no configurations or prefix (the common case), just
        // write the import directly inline.
        pieces.token(keyword);
        pieces.space();
        pieces.visit(directive.uri);
      } else {
        // Otherwise, allow splitting between the configurations and prefix.
        var sections = [
          pieces.build(() {
            pieces.token(keyword);
            pieces.space();
            pieces.visit(directive.uri);
          })
        ];

        for (var configuration in directive.configurations) {
          sections.add(nodePiece(configuration));
        }

        if (asKeyword != null) {
          sections.add(pieces.build(() {
            pieces.token(deferredKeyword, spaceAfter: true);
            pieces.token(asKeyword);
            pieces.space();
            pieces.visit(prefix!);
          }));
        }

        pieces.add(InfixPiece(const [], sections));
      }

      if (directive.combinators.isNotEmpty) {
        var combinators = <Piece>[];
        for (var combinatorNode in directive.combinators) {
          switch (combinatorNode) {
            case HideCombinator(hiddenNames: var names):
            case ShowCombinator(shownNames: var names):
              combinators.add(InfixPiece(const [], [
                tokenPiece(combinatorNode.keyword),
                for (var name in names)
                  tokenPiece(name.token, commaAfter: true),
              ]));
            default:
              throw StateError('Unknown combinator type $combinatorNode.');
          }
        }

        pieces.add(ClausePiece(combinators));
      }

      pieces.token(directive.semicolon);
    });
  }

  /// Writes a [Piece] for an index expression.
  void writeIndexExpression(IndexExpression index) {
    // TODO(tall): Consider whether we should allow splitting between
    // successive index expressions, like:
    //
    //     jsonData['some long key']
    //         ['another long key'];
    //
    // The current formatter allows it, but it's very rarely used (0.021% of
    // index expressions in a corpus of pub packages).
    pieces.token(index.question);
    pieces.token(index.period);
    pieces.token(index.leftBracket);
    pieces.visit(index.index);
    pieces.token(index.rightBracket);
  }

  /// Writes a single infix operation.
  ///
  /// If [hanging] is `true` then the operator goes at the end of the first
  /// line, like `+`. Otherwise, it goes at the beginning of the second, like
  /// `as`.
  ///
  /// The [operator2] parameter may be passed if the "operator" is actually two
  /// separate tokens, as in `foo is! Bar`.
  void writeInfix(AstNode left, Token operator, AstNode right,
      {bool hanging = false, Token? operator2}) {
    // Hoist any comments before the first operand so they don't force the
    // infix operator to split.
    var leadingComments = pieces.takeCommentsBefore(left.firstNonCommentToken);

    var leftPiece = pieces.build(() {
      pieces.visit(left);
      if (hanging) {
        pieces.space();
        pieces.token(operator);
        pieces.token(operator2);
      }
    });

    var rightPiece = pieces.build(() {
      if (!hanging) {
        pieces.token(operator);
        pieces.token(operator2);
        pieces.space();
      }

      pieces.visit(right);
    });

    pieces.add(InfixPiece(leadingComments, [leftPiece, rightPiece]));
  }

  /// Writes a chained infix operation: a binary operator expression, or
  /// binary pattern.
  ///
  /// In a tree of binary AST nodes, all operators at the same precedence are
  /// treated as a single chain of operators that either all split or none do.
  /// Operands within those (which may themselves be chains of higher
  /// precedence binary operators) are then formatted independently.
  ///
  /// [T] is the type of node being visited and [destructure] is a callback
  /// that takes one of those and yields the operands and operator. We need
  /// this since there's no interface shared by the various binary operator
  /// AST nodes.
  ///
  /// If [precedence] is given, then this only flattens binary nodes with that
  /// same precedence.
  void writeInfixChain<T extends AstNode>(
      T node, BinaryOperation Function(T node) destructure,
      {int? precedence, bool indent = true}) {
    // Hoist any comments before the first operand so they don't force the
    // infix operator to split.
    var leadingComments = pieces.takeCommentsBefore(node.firstNonCommentToken);

    var operands = <Piece>[];

    void traverse(AstNode e) {
      // If the node is one if our infix operators, then recurse into the
      // operands.
      if (e is T) {
        var (left, operator, right) = destructure(e);
        if (precedence == null || operator.type.precedence == precedence) {
          operands.add(pieces.build(() {
            traverse(left);
            pieces.space();
            pieces.token(operator);
          }));

          traverse(right);
          return;
        }
      }

      // Otherwise, just write the node itself.
      pieces.visit(e);
    }

    operands.add(pieces.build(() {
      traverse(node);
    }));

    pieces.add(InfixPiece(leadingComments, operands, indent: indent));
  }

  /// Writes a [ListPiece] for the given bracket-delimited set of elements.
  ///
  /// If [preserveNewlines] is `true`, then any newlines or lack of newlines
  /// between pairs of elements in the input are preserved in the output. This
  /// is used for collection literals that contain line comments to preserve
  /// the author's deliberate structuring, as in:
  ///
  ///     matrix = [
  ///       1, 2, 3, //
  ///       4, 5, 6,
  ///       7, 8, 9,
  ///     ];
  void writeList(List<AstNode> elements,
      {required Token leftBracket,
      required Token rightBracket,
      ListStyle style = const ListStyle(),
      bool preserveNewlines = false}) {
    // If the list is completely empty, write the brackets directly inline so
    // that we create fewer pieces.
    if (!elements.canSplit(rightBracket)) {
      pieces.token(leftBracket);
      pieces.token(rightBracket);
      return;
    }

    var builder = DelimitedListBuilder(this, style);

    builder.leftBracket(leftBracket);

    if (preserveNewlines && elements.containsLineComments(rightBracket)) {
      _preserveNewlinesInCollection(elements, builder);
    } else {
      elements.forEach(builder.visit);
    }

    builder.rightBracket(rightBracket);
    pieces.add(builder.build());
  }

  /// Writes [elements] into [builder], preserving the original newlines (or
  /// lack thereof) between elements.
  ///
  /// This is used for formatting collection literals that contain at least one
  /// line comment between elements. In that case, we use the line comment as a
  /// single to prefer the author's chosen newlines between elements. For
  /// example, if the user writes:
  ///
  ///     list = [
  ///       1,2,   3, 4,
  ///       // comment
  ///       5,6,    7
  ///     ];
  ///
  /// The formatter produces:
  ///
  ///     list = [
  ///       1, 2, 3, 4,
  ///       // comment
  ///       5, 6, 7
  ///     ];
  void _preserveNewlinesInCollection(
      List<AstNode> elements, DelimitedListBuilder builder) {
    // Builder for all of the elements on a single line. We use a ListPiece for
    // this too because even though we prefer to keep all elements that are on
    // a single line in the input also on a single line in the output, we will
    // split them if they don't fit.
    var lineStyle = const ListStyle(commas: Commas.nonTrailing);
    var lineBuilder = DelimitedListBuilder(this, lineStyle);
    var atLineStart = true;

    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];

      if (!atLineStart &&
          comments.hasNewlineBetween(
              elements[i - 1].endToken, element.beginToken)) {
        // This element begins a new line. Add the elements on the previous
        // line to the list builder and start a new line.
        builder.add(lineBuilder.build());
        lineBuilder = DelimitedListBuilder(this, lineStyle);
        atLineStart = true;
      }

      // Let the main list builder handle comments that occur between elements
      // that aren't on the same line.
      if (atLineStart) builder.addCommentsBefore(element.beginToken);

      lineBuilder.visit(element);

      // There is an element on this line now.
      atLineStart = false;
    }

    if (!atLineStart) builder.add(lineBuilder.build());
  }

  /// Writes a [VariablePiece] for a named or wildcard variable pattern.
  void writePatternVariable(Token? keyword, TypeAnnotation? type, Token name) {
    // If it's a wildcard with no declaration keyword or type, there is just a
    // name token.
    if (keyword == null && type == null) {
      pieces.token(name);
      return;
    }

    var header = pieces.build(() {
      pieces.modifier(keyword);
      pieces.visit(type);
    });

    pieces
        .add(VariablePiece(header, [tokenPiece(name)], hasType: type != null));
  }

  /// Writes a [Piece] for an AST node followed by an unsplittable token.
  void writePostfix(AstNode node, Token? operator) {
    pieces.visit(node);
    pieces.token(operator);
  }

  /// Writes a [Piece] for an AST node preceded by an unsplittable token.
  ///
  /// If [space] is `true` and there is an operator, writes a space between the
  /// operator and operand.
  void writePrefix(Token? operator, AstNode? node, {bool space = false}) {
    pieces.token(operator, spaceAfter: space);
    pieces.visit(node);
  }

  /// Writes an [AdjacentPiece] for a given record type field.
  void writeRecordTypeField(RecordTypeAnnotationField node) {
    writeParameter(metadata: node.metadata, node.type, node.name);
  }

  /// Writes a [ListPiece] for a record literal or pattern.
  void writeRecord(
    Token leftParenthesis,
    List<AstNode> fields,
    Token rightParenthesis, {
    Token? constKeyword,
    bool preserveNewlines = false,
  }) {
    var style = switch (fields) {
      // Record types or patterns with a single named field don't add a trailing
      // comma unless it's split, like:
      //
      //     ({int n}) x;
      //
      // Or:
      //
      //     if (obj case (name: value)) {
      //       ;
      //     }
      [PatternField(name: _?)] => const ListStyle(commas: Commas.trailing),
      [NamedExpression()] => const ListStyle(commas: Commas.trailing),

      // Record types or patterns with a single positional field always have a
      // trailing comma to disambiguate from parenthesized expressions or
      // patterns, like:
      //
      //     (int,) x;
      //
      // Or:
      //
      //     if (obj case (pattern,)) {
      //       ;
      //     }
      [_] => const ListStyle(commas: Commas.alwaysTrailing),

      // Record types or patterns with multiple fields have regular trailing
      // commas when split.
      _ => const ListStyle(commas: Commas.trailing)
    };

    writeCollection(
      constKeyword: constKeyword,
      leftParenthesis,
      fields,
      rightParenthesis,
      style: style,
      preserveNewlines: preserveNewlines,
    );
  }

  /// Writes a class, enum, extension, extension type, mixin, or mixin
  /// application class declaration.
  ///
  /// The [keywords] list is the ordered list of modifiers and keywords at the
  /// beginning of the declaration.
  ///
  /// For all but a mixin application class, [body] should a record containing
  /// the bracket delimiters and the list of member declarations for the type's
  /// body. For mixin application classes, [body] is `null` and instead
  /// [equals], [superclass], and [semicolon] are provided.
  ///
  /// If the type is an extension, then [onType] is a record containing the
  /// `on` keyword and the on type.
  ///
  /// If the type is an extension type, then [representation] is the primary
  /// constructor for it.
  void writeType(
      NodeList<Annotation> metadata, List<Token?> keywords, Token? name,
      {TypeParameterList? typeParameters,
      Token? equals,
      NamedType? superclass,
      RepresentationDeclaration? representation,
      ExtendsClause? extendsClause,
      MixinOnClause? onClause,
      WithClause? withClause,
      ImplementsClause? implementsClause,
      NativeClause? nativeClause,
      (Token, TypeAnnotation)? onType,
      TypeBodyType bodyType = TypeBodyType.block,
      required Piece Function() body}) {
    // Begin a piece to attach the metadata to the type.
    pieces.withMetadata(metadata, () {
      var header = pieces.build(() {
        var space = false;
        for (var keyword in keywords) {
          if (space) pieces.space();
          pieces.token(keyword);
          if (keyword != null) space = true;
        }

        pieces.token(name, spaceBefore: true);

        if (typeParameters != null) {
          pieces.visit(typeParameters);
        }

        // Mixin application classes have ` = Superclass` after the declaration
        // name.
        if (equals != null) {
          pieces.space();
          pieces.token(equals);
          pieces.space();
          pieces.visit(superclass!);
        }

        // Extension types have a representation type.
        if (representation != null) {
          pieces.visit(representation);
        }
      });

      var clauses = <Piece>[];

      void typeClause(Token keyword, List<AstNode> types) {
        clauses.add(InfixPiece(const [], [
          tokenPiece(keyword),
          for (var type in types) nodePiece(type, commaAfter: true),
        ]));
      }

      if (extendsClause != null) {
        typeClause(extendsClause.extendsKeyword, [extendsClause.superclass]);
      }

      if (onClause != null) {
        typeClause(onClause.onKeyword, onClause.superclassConstraints);
      }

      if (withClause != null) {
        typeClause(withClause.withKeyword, withClause.mixinTypes);
      }

      if (implementsClause != null) {
        typeClause(
            implementsClause.implementsKeyword, implementsClause.interfaces);
      }

      if (onType case (var onKeyword, var onType)?) {
        typeClause(onKeyword, [onType]);
      }

      if (nativeClause != null) {
        typeClause(nativeClause.nativeKeyword,
            [if (nativeClause.name case var name?) name]);
      }

      ClausePiece? clausesPiece;
      if (clauses.isNotEmpty) {
        clausesPiece = ClausePiece(clauses,
            allowLeadingClause: extendsClause != null || onClause != null);
      }

      var bodyPiece = body();

      pieces
          .add(TypePiece(header, clausesPiece, bodyPiece, bodyType: bodyType));
    });
  }

  /// Writes a [ListPiece] for a type argument or type parameter list.
  void writeTypeList(
      Token leftBracket, List<AstNode> elements, Token rightBracket) {
    writeList(
        leftBracket: leftBracket,
        elements,
        rightBracket: rightBracket,
        style: const ListStyle(commas: Commas.nonTrailing, splitCost: 3));
  }

  /// Handles the `async`, `sync*`, or `async*` modifiers on a function body.
  void writeFunctionBodyModifiers(FunctionBody body) {
    // The `async` or `sync` keyword.
    pieces.token(body.keyword);
    pieces.token(body.star);
    if (body.keyword != null) pieces.space();
  }

  /// Writes a [Piece] with "assignment-like" splitting.
  ///
  /// This is used, obviously, for assignments and variable declarations to
  /// handle splitting after the `=`, but is also used in any context where an
  /// expression follows something that it "defines" or "initializes":
  ///
  /// * Assignment
  /// * Variable declaration
  /// * Constructor initializer
  /// * Expression (`=>`) function body
  /// * Named argument or named record field (`:`)
  /// * Map entry (`:`)
  ///
  /// If [canBlockSplitLeft] is `true`, then the left-hand operand supports
  /// being block-formatted without indenting it farther, like:
  ///
  ///     var [
  ///       element,
  ///     ] = list;
  void writeAssignment(
      AstNode leftHandSide, Token operator, AstNode rightHandSide,
      {bool includeComma = false,
      bool canBlockSplitLeft = false,
      NodeContext leftHandSideContext = NodeContext.none}) {
    // If an operand can have block formatting, then a newline in it doesn't
    // force the operator to split, as in:
    //
    //    var [
    //      element,
    //    ] = list;
    //
    // Or:
    //
    //    var list = [
    //      element,
    //    ];
    canBlockSplitLeft |= switch (leftHandSide) {
      Expression() => leftHandSide.canBlockSplit,
      DartPattern() => leftHandSide.canBlockSplit,
      _ => false
    };

    var canBlockSplitRight = switch (rightHandSide) {
      Expression() => rightHandSide.canBlockSplit,
      DartPattern() => rightHandSide.canBlockSplit,
      _ => false
    };

    var leftPiece = nodePiece(leftHandSide, context: leftHandSideContext);

    var operatorPiece = pieces.build(() {
      if (operator.type != TokenType.COLON) pieces.space();
      pieces.token(operator);
    });

    var rightPiece = nodePiece(rightHandSide,
        commaAfter: includeComma, context: NodeContext.assignment);

    pieces.add(AssignPiece(
        left: leftPiece,
        operatorPiece,
        rightPiece,
        canBlockSplitLeft: canBlockSplitLeft,
        canBlockSplitRight: canBlockSplitRight));
  }

  /// Writes a [Piece] for the `<variable> in <expression>` part of a for-in
  /// loop.
  void writeForIn(AstNode leftHandSide, Token inKeyword, Expression sequence) {
    var leftPiece =
        nodePiece(leftHandSide, context: NodeContext.forLoopVariable);

    var sequencePiece = pieces.build(() {
      // Put the `in` at the beginning of the sequence.
      pieces.token(inKeyword);
      pieces.space();
      pieces.visit(sequence);
    });

    pieces.add(ForInPiece(leftPiece, sequencePiece,
        canBlockSplitSequence: sequence.canBlockSplit));
  }

  /// Writes a piece for a parameter-like constructor: Either a simple formal
  /// parameter or a record type field, which is syntactically similar to a
  /// parameter.
  ///
  /// If the parameter has a default value, then [defaultValue] contains the
  /// `:` or `=` separator and the constant value expression.
  void writeParameter(TypeAnnotation? type, Token? name,
      {List<Annotation> metadata = const [],
      List<Token?> modifiers = const [],
      Token? fieldKeyword,
      Token? period,
      (Token separator, Expression value)? defaultValue}) {
    // Begin a piece to attach metadata to the parameter.
    pieces.withMetadata(metadata, inlineMetadata: true, () {
      Piece? typePiece;
      if (type != null) {
        typePiece = pieces.build(() {
          for (var keyword in modifiers) {
            pieces.modifier(keyword);
          }

          pieces.visit(type);
        });
      }

      Piece? namePiece;
      if (name != null) {
        namePiece = pieces.build(() {
          // If there is a type annotation, the modifiers will be before the
          // type. Otherwise, they go before the name.
          if (type == null) {
            for (var keyword in modifiers) {
              pieces.modifier(keyword);
            }
          }

          pieces.token(fieldKeyword);
          pieces.token(period);
          pieces.token(name);
        });
      }

      Piece parameterPiece;
      if (typePiece != null && namePiece != null) {
        // We have both a type and name, allow splitting between them.
        parameterPiece = VariablePiece(typePiece, [namePiece], hasType: true);
      } else {
        // Will have at least a type or name.
        parameterPiece = typePiece ?? namePiece!;
      }

      // If there's a default value, include it. We do that inside here so that
      // any metadata surrounds the entire assignment instead of being part of
      // the assignment's left-hand side where a split in the metadata would
      // force a split at the default value separator.
      writeDefaultValue(parameterPiece, defaultValue);
    });
  }

  /// Visits [node] and creates a piece from it.
  ///
  /// If [commaAfter] is `true`, looks for a comma token after [node] and
  /// writes it to the piece as well.
  Piece nodePiece(AstNode node,
      {bool commaAfter = false, NodeContext context = NodeContext.none}) {
    var result = pieces.build(() {
      visitNode(node, context);
    });

    if (commaAfter) {
      var nextToken = node.endToken.next!;
      if (nextToken.lexeme == ',') {
        var comma = tokenPiece(nextToken);
        result = AdjacentPiece([result, comma]);
      }
    }

    return result;
  }

  /// Visits [node] and creates a piece from it if not `null`.
  ///
  /// Otherwise returns `null`.
  Piece? optionalNodePiece(AstNode? node) {
    if (node == null) return null;
    return nodePiece(node);
  }

  /// Creates a piece for only [token].
  ///
  /// If [commaAfter] is `true`, will look for and write a comma following the
  /// token if there is one.
  Piece tokenPiece(Token token, {bool commaAfter = false}) {
    return pieces.tokenPiece(token, commaAfter: commaAfter);
  }
}
