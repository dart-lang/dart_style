// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../dart_formatter.dart';
import '../piece/sequence.dart';
import '../source_code.dart';
import 'comment_writer.dart';
import 'piece_factory.dart';
import 'piece_writer.dart';

/// Visits every token of the AST and produces a tree of [Piece]s that
/// corresponds to it and contains every token and comment in the original
/// source.
///
/// To avoid this class becoming a monolith, functionality is divided into a
/// couple of mixins, one for each area of functionality. This class then
/// contains only shared state and the visitor methods for the AST.
class AstNodeVisitor extends ThrowingAstVisitor<void>
    with CommentWriter, PieceFactory {
  /// Cached line info for calculating blank lines.
  @override
  final LineInfo lineInfo;

  @override
  final PieceWriter writer;

  /// Initialize a newly created visitor to write source code representing
  /// the visited nodes to the given [writer].
  AstNodeVisitor(DartFormatter formatter, this.lineInfo, SourceCode source)
      : writer = PieceWriter(formatter, source);

  /// Runs the visitor on [node], formatting its contents.
  ///
  /// Returns a [SourceCode] containing the resulting formatted source and
  /// updated selection, if any.
  ///
  /// This is the only method that should be called externally. Everything else
  /// is effectively private.
  SourceCode run(AstNode node) {
    visit(node);

    // Finish writing and return the complete result.
    return writer.finish();
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    throw UnimplementedError();
  }

  @override
  void visitAnnotation(Annotation node) {
    throw UnimplementedError();
  }

  @override
  void visitArgumentList(ArgumentList node, {bool nestExpression = true}) {
    throw UnimplementedError();
  }

  @override
  void visitAsExpression(AsExpression node) {
    createInfix(node.expression, node.asOperator, node.type);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    throw UnimplementedError();
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    createInfixChain<BinaryExpression>(
        node,
        precedence: node.operator.type.precedence,
        (expression) => (
              expression.leftOperand,
              expression.operator,
              expression.rightOperand
            ));
  }

  @override
  void visitBlock(Block node) {
    createBlock(node.leftBracket, node.statements, node.rightBracket);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    token(node.literal);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitCastPattern(CastPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitCatchClause(CatchClause node) {
    throw UnimplementedError();
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  void visitComment(Comment node) {
    throw UnimplementedError();
  }

  @override
  void visitCommentReference(CommentReference node) {
    throw UnimplementedError();
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    var sequence = SequencePiece();

    if (node.scriptTag case var scriptTag?) {
      addToSequence(sequence, scriptTag);
      sequence.addBlank();
    }

    // Put a blank line between the library tag and the other directives.
    Iterable<Directive> directives = node.directives;
    if (directives.isNotEmpty && directives.first is LibraryDirective) {
      addToSequence(sequence, directives.first);
      sequence.addBlank();
      directives = directives.skip(1);
    }

    for (var directive in directives) {
      addToSequence(sequence, directive);
    }

    // TODO(tall): Handle top level declarations.
    if (node.declarations.isNotEmpty) throw UnimplementedError();

    // Write any comments at the end of the file.
    beforeSequenceNode(sequence);
    writeCommentsAndBlanksBefore(node.endToken.next!);

    writer.push(sequence);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitConfiguration(Configuration node) {
    token(node.ifKeyword);
    writer.space();
    token(node.leftParenthesis);

    if (node.equalToken case var equals?) {
      createInfix(node.name, equals, node.value!, hanging: true);
    } else {
      visit(node.name);
    }

    token(node.rightParenthesis);
    writer.space();
    visit(node.uri);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    throw UnimplementedError();
  }

  @override
  void visitConstructorName(ConstructorName node) {
    throw UnimplementedError();
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    throw UnimplementedError();
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    throw UnimplementedError();
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitDoStatement(DoStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitDottedName(DottedName node) {
    createDotted(node.components);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitEmptyFunctionBody(EmptyFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {
    token(node.semicolon);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitExportDirective(ExportDirective node) {
    createImport(node, node.exportKeyword);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    token(node.semicolon);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    throw UnimplementedError();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    throw UnimplementedError();
  }

  @override
  void visitForElement(ForElement node) {
    throw UnimplementedError();
  }

  @override
  void visitForStatement(ForStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    throw UnimplementedError();
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    throw UnimplementedError();
  }

  @override
  void visitForPartsWithExpression(ForPartsWithExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitForPartsWithPattern(ForPartsWithPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    throw UnimplementedError();
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    throw UnimplementedError();
  }

  @override
  void visitHideCombinator(HideCombinator node) {
    throw UnimplementedError();
  }

  @override
  void visitIfElement(IfElement node) {
    throw UnimplementedError();
  }

  @override
  void visitIfStatement(IfStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    throw UnimplementedError();
  }

  @override
  void visitImportDirective(ImportDirective node) {
    createImport(node, node.importKeyword,
        deferredKeyword: node.deferredKeyword,
        asKeyword: node.asKeyword,
        prefix: node.prefix);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    token(node.literal);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    throw UnimplementedError();
  }

  @override
  void visitIsExpression(IsExpression node) {
    createInfix(
        node.expression,
        node.isOperator,
        operator2: node.notOperator,
        node.type);
  }

  @override
  void visitLabel(Label node) {
    visit(node.label);
    token(node.colon);
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    var sequence = SequencePiece();

    for (var label in node.labels) {
      addToSequence(sequence, label);
    }

    addToSequence(sequence, node.statement);

    writer.push(sequence);
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    createDirectiveMetadata(node);
    token(node.libraryKeyword);
    visit(node.name2, before: writer.space);
    token(node.semicolon);
  }

  @override
  void visitLibraryIdentifier(LibraryIdentifier node) {
    createDotted(node.components);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitListPattern(ListPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitLogicalAndPattern(LogicalAndPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitLogicalOrPattern(LogicalOrPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    throw UnimplementedError();
  }

  @override
  void visitMapPattern(MapPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    throw UnimplementedError();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitNamedType(NamedType node) {
    // TODO(tall): Handle import prefix.
    if (node.importPrefix != null) throw UnimplementedError();

    token(node.name2);

    // TODO(tall): Handle type arguments.
    if (node.typeArguments != null) throw UnimplementedError();

    // TODO(tall): Handle nullable types.
    if (node.question != null) throw UnimplementedError();
  }

  @override
  void visitNativeClause(NativeClause node) {
    throw UnimplementedError();
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    throw UnimplementedError();
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitNullCheckPattern(NullCheckPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitObjectPattern(ObjectPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitOnClause(OnClause node) {
    throw UnimplementedError();
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitParenthesizedPattern(ParenthesizedPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitPartDirective(PartDirective node) {
    createDirectiveMetadata(node);
    token(node.partKeyword);
    writer.space();
    visit(node.uri);
    token(node.semicolon);
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    createDirectiveMetadata(node);
    token(node.partKeyword);
    writer.space();
    token(node.ofKeyword);
    writer.space();

    // Part-of may have either a name or a URI. Only one of these will be
    // non-null. We visit both since visit() ignores null.
    visit(node.libraryName);
    visit(node.uri);
    token(node.semicolon);
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternField(PatternField node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitPatternVariableDeclarationStatement(
      PatternVariableDeclarationStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    throw UnimplementedError();
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    throw UnimplementedError();
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordPattern(RecordPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotation(RecordTypeAnnotation node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotationNamedField(
      RecordTypeAnnotationNamedField node) {
    throw UnimplementedError();
  }

  @override
  void visitRecordTypeAnnotationPositionalField(
      RecordTypeAnnotationPositionalField node) {
    throw UnimplementedError();
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitRestPatternElement(RestPatternElement node) {
    throw UnimplementedError();
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitScriptTag(ScriptTag node) {
    // The lexeme includes the trailing newline. Strip it off since the
    // formatter ensures it gets a newline after it. Since the script tag must
    // come at the top of the file, we don't have to worry about preceding
    // comments or whitespace.
    // TODO(new-ir): Update selection if inside the script tag.
    writer.write(node.scriptTag.lexeme.trim());
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    throw UnimplementedError();
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    token(node.token);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    token(node.literal);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    throw UnimplementedError();
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    throw UnimplementedError();
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    throw UnimplementedError();
  }

  @override
  void visitThisExpression(ThisExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    throw UnimplementedError();
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitTryStatement(TryStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    throw UnimplementedError();
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    throw UnimplementedError();
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    throw UnimplementedError();
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    throw UnimplementedError();
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    throw UnimplementedError();
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    throw UnimplementedError();
  }

  @override
  void visitWildcardPattern(WildcardPattern node) {
    throw UnimplementedError();
  }

  @override
  void visitWithClause(WithClause node) {
    throw UnimplementedError();
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    throw UnimplementedError();
  }

  /// If [node] is not `null`, then visit it.
  ///
  /// Invokes [before] before visiting [node], and [after] afterwards, but only
  /// if [node] is present.
  @override
  void visit(AstNode? node, {void Function()? before, void Function()? after}) {
    if (node == null) return;

    if (before != null) before();
    node.accept(this);
    if (after != null) after();
  }
}
