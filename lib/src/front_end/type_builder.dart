// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../ast_extensions.dart';
import '../piece/clause.dart';
import '../piece/infix.dart';
import '../piece/list.dart';
import '../piece/piece.dart';
import '../piece/type.dart';
import 'delimited_list_builder.dart';
import 'piece_factory.dart';
import 'sequence_builder.dart';

/// Builds pieces for a class, enum, extension, extension type, mixin, or mixin
/// application class declaration.
final class TypeBuilder {
  final PieceFactory _visitor;
  final NodeList<Annotation> _metadata;
  final List<Token?> _keywords;
  final Token? _name;
  final TypeParameterList? _typeParameters;

  final List<_Clause> _clauses;

  /// Whether the first clause can be on the same line as the header even if
  /// the other clauses split.
  bool _allowLeadingClause = false;

  TypeBuilder(
    this._visitor,
    this._metadata,
    this._keywords, {
    Token? name,
    TypeParameterList? typeParameters,
    ExtendsClause? extendsClause,
    WithClause? withClause,
    ImplementsClause? implementsClause,
    MixinOnClause? mixinOnClause,
    ExtensionOnClause? extensionOnClause,
    NativeClause? nativeClause,
  }) : _name = name,
       _clauses = [
         if (extendsClause case var clause?)
           _Clause(clause.extendsKeyword, [clause.superclass]),
         if (mixinOnClause case var clause?)
           _Clause(clause.onKeyword, clause.superclassConstraints),
         if (withClause case var clause?)
           _Clause(clause.withKeyword, clause.mixinTypes),
         if (implementsClause case var clause?)
           _Clause(clause.implementsKeyword, clause.interfaces),
         if (extensionOnClause case var clause?)
           _Clause(clause.onKeyword, [clause.extendedType]),
         if (nativeClause case var clause?)
           _Clause(clause.nativeKeyword, [?clause.name]),
       ],
       _typeParameters = typeParameters {
    _allowLeadingClause = extendsClause != null || mixinOnClause != null;
  }

  void buildBlockBody(
    Token leftBrace,
    List<AstNode> contents,
    Token rightBrace,
  ) {
    _visitor.pieces.withMetadata(_metadata, () {
      var header = _visitor.pieces.build(_writeHeader);
      header = _writeClauses(header);

      var body = _visitor.pieces.build(() {
        _visitor.writeBody(leftBrace, contents, rightBrace);
      });

      _visitor.pieces.add(
        TypePiece(header, body, bodyType: TypeBodyType.block),
      );
    });
  }

  void buildClassBody({
    required PrimaryConstructorDeclaration? primaryConstructor,
    required ClassBody body,
  }) {
    _visitor.pieces.withMetadata(_metadata, () {
      var header = _visitor.pieces.build(() {
        _writeHeader();

        if (primaryConstructor != null) {
          _visitor.pieces.visit(primaryConstructor, spaceBefore: true);
        }
      });

      header = _writeClauses(header);

      var bodyPiece = switch (body) {
        BlockClassBody() => _visitor.pieces.build(() {
          _visitor.writeBody(body.leftBracket, body.members, body.rightBracket);
        }),
        EmptyClassBody body => _visitor.pieces.tokenPiece(body.semicolon),
      };

      _visitor.pieces.add(
        TypePiece(
          header,
          bodyPiece,
          bodyType: switch (body) {
            BlockClassBody() => TypeBodyType.block,
            EmptyClassBody() => TypeBodyType.semicolon,
          },
        ),
      );
    });
  }

  void buildEnum(EnumDeclaration node) {
    var bodyType = node.body.members.isEmpty
        ? TypeBodyType.list
        : TypeBodyType.block;
    _visitor.pieces.withMetadata(_metadata, () {
      var header = _visitor.pieces.build(_writeHeader);
      header = _writeClauses(header);

      var body = node.body.members.isEmpty
          ? _normalEnumBody(node.body)
          : _enhancedEnumBody(node.body);

      _visitor.pieces.add(TypePiece(header, body, bodyType: bodyType));
    });
  }

  /// Builds a [Piece] for the body of an enum declaration with values but not
  /// members.
  ///
  /// Formats the constants like a list. This keeps the enum declaration on one
  /// line if it fits.
  Piece _normalEnumBody(EnumBody body) {
    var builder = DelimitedListBuilder(
      _visitor,
      const ListStyle(spaceWhenUnsplit: true),
    );

    builder.leftBracket(body.leftBracket);
    body.constants.forEach(builder.visit);
    builder.rightBracket(semicolon: body.semicolon, body.rightBracket);
    return builder.build(
      forceSplit: _visitor.style.preserveTrailingCommaBefore(
        body.semicolon ?? body.rightBracket,
      ),
    );
  }

  /// Builds a [Piece] for the body of an enum declaration with members.
  ///
  /// Formats it like a block where each constant or member is on its own line.
  Piece _enhancedEnumBody(EnumBody body) {
    // If there are members,
    var builder = SequenceBuilder(_visitor);
    builder.leftBracket(body.leftBracket);

    // In 3.10 and later, preserved trailing commas will also preserve a
    // trailing comma in an enum with members. That in turn forces the `;` onto
    // its own line after the last costant. Prior to 3.10, the behavior is the
    // same as when preserved trailing commas is off where the last constant's
    // comma is removed and the `;` is placed there instead.
    for (var constant in body.constants) {
      var isLast = constant == body.constants.last;
      builder.addCommentsBefore(constant.firstNonCommentToken);
      builder.add(
        _visitor.createEnumConstant(
          constant,
          commaAfter:
              !isLast || _visitor.style.preserveTrailingCommaAfterEnumValues,
          semicolon: isLast ? body.semicolon : null,
        ),
      );
    }

    // If we are preserving the trailing comma, then put the `;` on its own line
    // after the last constant.
    if (_visitor.style.preserveTrailingCommaAfterEnumValues) {
      builder.add(_visitor.tokenPiece(body.semicolon!));
    }

    // Insert a blank line between the constants and members.
    builder.addBlank();

    for (var member in body.members) {
      builder.visit(member);

      // If the node has a non-empty braced body, then require a blank
      // line between it and the next node.
      if (member.hasNonEmptyBody) builder.addBlank();
    }

    builder.rightBracket(body.rightBracket);
    return builder.build();
  }

  void buildMixinApplicationClass(
    Token equals,
    NamedType superclass,
    Token semicolon,
  ) {
    _visitor.pieces.withMetadata(_metadata, () {
      var header = _visitor.pieces.build(() {
        _writeHeader();

        // Mixin application classes have ` = Superclass` after the declaration
        // name.
        _visitor.pieces.space();
        _visitor.pieces.token(equals);
        _visitor.pieces.space();
        _visitor.pieces.visit(superclass);
      });

      header = _writeClauses(header);

      _visitor.pieces.add(
        TypePiece(
          header,
          _visitor.tokenPiece(semicolon),
          bodyType: TypeBodyType.semicolon,
        ),
      );
    });
  }

  /// Writes the leading keywords, name, and type parameters for the type.
  void _writeHeader() {
    var space = false;
    for (var keyword in _keywords) {
      if (space) _visitor.pieces.space();
      _visitor.pieces.token(keyword);
      if (keyword != null) space = true;
    }

    _visitor.pieces.token(_name, spaceBefore: true);

    if (_typeParameters case var typeParameters?) {
      _visitor.pieces.visit(typeParameters);
    }
  }

  /// If there are any clauses, wraps [header] in a [ClausePiece] for them.
  Piece _writeClauses(Piece header) {
    if (_clauses.isEmpty) return header;

    return ClausePiece(header, [
      for (var clause in _clauses) clause.build(_visitor),
    ], allowLeadingClause: _allowLeadingClause);
  }
}

/// A single `extends`, `with`, etc. clause that goes in a type header.
final class _Clause {
  final Token keyword;
  final List<AstNode> types;

  _Clause(this.keyword, this.types);

  Piece build(PieceFactory visitor) => InfixPiece([
    visitor.tokenPiece(keyword),
    for (var type in types) visitor.nodePiece(type, commaAfter: true),
  ], is3Dot7: visitor.style.is3Dot7);
}
