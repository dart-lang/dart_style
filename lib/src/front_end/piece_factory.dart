// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../piece/import.dart';
import '../piece/piece.dart';
import '../piece/postfix.dart';
import '../piece/sequence.dart';
import 'piece_writer.dart';

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
  PieceWriter get writer;

  void visit(AstNode? node, {void Function()? before, void Function()? after});

  /// Adds [node] to [sequence], handling blank lines around it.
  void addToSequence(SequencePiece sequence, AstNode node) {
    visit(node);
    sequence.add(writer.pop());
    writer.split();
  }

  /// Creates metadata annotations for a directive.
  ///
  /// Always forces the annotations to be on a previous line.
  void createDirectiveMetadata(Directive directive) {
    // TODO(tall): Implement. See SourceVisitor._visitDirectiveMetadata().
    if (directive.metadata.isNotEmpty) throw UnimplementedError();
  }

  /// Creates a dotted or qualified identifier.
  void createDotted(NodeList<SimpleIdentifier> components) {
    for (var component in components) {
      // Write the preceding ".".
      if (component != components.first) {
        token(component.beginToken.previous);
      }

      visit(component);
    }
  }

  /// Creates an [ImportPiece] for an import or export directive.
  void createImport(NamespaceDirective directive, Token keyword,
      {Token? deferredKeyword, Token? asKeyword, SimpleIdentifier? prefix}) {
    createDirectiveMetadata(directive);
    token(keyword);
    writer.space();
    visit(directive.uri);
    var directivePiece = writer.pop();

    Piece? asClause;
    if (asKeyword != null) {
      writer.split();
      token(deferredKeyword, after: writer.space);
      token(asKeyword);
      writer.space();
      visit(prefix);
      asClause = PostfixPiece([writer.pop()]);
    }

    var combinators = <ImportCombinator>[];
    for (var combinatorNode in directive.combinators) {
      writer.split();
      token(combinatorNode.keyword);
      var combinator = ImportCombinator(writer.pop());
      combinators.add(combinator);

      switch (combinatorNode) {
        case HideCombinator(hiddenNames: var names):
        case ShowCombinator(shownNames: var names):
          for (var name in names) {
            writer.split();
            token(name.token);
            commaAfter(name);
            combinator.names.add(writer.pop());
          }
        default:
          throw StateError('Unknown combinator type $combinatorNode.');
      }
    }

    var combinator = switch (combinators.length) {
      0 => null,
      1 => OneCombinatorPiece(combinators[0]),
      2 => TwoCombinatorPiece(combinators),
      _ => throw StateError('Directives can only have up to two combinators.'),
    };

    token(directive.semicolon);

    writer.push(ImportPiece(directivePiece, asClause, combinator));
  }

  /// Emit [token], along with any comments and formatted whitespace that comes
  /// before it.
  ///
  /// Does nothing if [token] is `null`. If [before] is given, it will be
  /// executed before the token is outout. Likewise, [after] will be called
  /// after the token is output.
  void token(Token? token, {void Function()? before, void Function()? after}) {
    if (token == null) return;

    // TODO(tall): Write comments before the token.

    if (before != null) before();
    writeLexeme(token.lexeme);
    if (after != null) after();
  }

  /// Writes the raw [lexeme] to the current text piece.
  void writeLexeme(String lexeme) {
    // TODO(tall): Preserve selection.
    writer.write(lexeme);
  }

  /// Writes a comma after [node], if there is one.
  void commaAfter(AstNode node, {bool trailing = false}) {
    var nextToken = node.endToken.next!;
    if (nextToken.lexeme == ',') {
      token(nextToken);
    } else if (trailing) {
      // If there isn't a comma there, it must be a place where a trailing
      // comma can appear, so synthesize it. During formatting, we will decide
      // whether to include it.
      writeLexeme(',');
    }
  }
}
