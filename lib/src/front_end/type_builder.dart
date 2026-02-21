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
  final ClassNamePart? _namePart;

  final List<_Clause> _clauses;

  /// Whether the first clause can be on the same line as the header even if
  /// the other clauses split.
  final bool _allowLeadingClause;

  TypeBuilder(
    this._visitor,
    this._metadata,
    this._keywords, {
    Token? name,
    TypeParameterList? typeParameters,
    ClassNamePart? namePart,
    ExtendsClause? extendsClause,
    WithClause? withClause,
    ImplementsClause? implementsClause,
    MixinOnClause? mixinOnClause,
    ExtensionOnClause? extensionOnClause,
    NativeClause? nativeClause,
  }) : _name = name,
       _typeParameters = typeParameters,
       _namePart = namePart,
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
       _allowLeadingClause = extendsClause != null || mixinOnClause != null {
    // Can have a name part or explicit name and type parameters, but not both.
    assert(_name == null && _typeParameters == null || _namePart == null);
  }

  /// Builds a type whose body is an explicit brace-delimited list of [members].
  void buildBlockBody(
    Token leftBrace,
    List<AstNode> members,
    Token rightBrace,
  ) {
    Piece buildBody() => _visitor.pieces.build(() {
      _visitor.writeBody(leftBrace, members, rightBrace);
    });

    _buildType(buildBody, TypeBodyType.block);
  }

  /// Builds a type whose [body] is a [ClassBody].
  void buildClassBody(ClassBody body) {
    Piece buildBody() => switch (body) {
      BlockClassBody() => _visitor.pieces.build(() {
        _visitor.writeBody(body.leftBracket, body.members, body.rightBracket);
      }),
      EmptyClassBody body => _visitor.pieces.tokenPiece(body.semicolon),
    };

    _buildType(buildBody, switch (body) {
      BlockClassBody() => TypeBodyType.block,
      EmptyClassBody() => TypeBodyType.semicolon,
    });
  }

  /// Builds an enum type.
  void buildEnum(EnumDeclaration node) {
    Piece buildBody() {
      // If the enum has any members we definitely need to force the body to
      // split because there are `;` in there. If it has a primary constructor,
      // we could allow it on one line. But users generally wish were more
      // eager to split and having the constructor and values all on one line
      // is pretty hard to read:
      //
      //     enum E(final int x) { a(1), b(2) }
      //
      // So always force the body to split if there is a primary constructor.
      if (node.body.members.isEmpty &&
          node.namePart is! PrimaryConstructorDeclaration) {
        return _buildNormalEnumBody(node.body);
      } else {
        return _buildEnhancedEnumBody(node.body);
      }
    }

    _buildType(
      buildBody,
      node.body.members.isEmpty ? TypeBodyType.list : TypeBodyType.block,
    );
  }

  /// Builds a mixin application class.
  void buildMixinApplicationClass(
    Token equals,
    NamedType superclass,
    Token semicolon,
  ) {
    _visitor.pieces.withMetadata(_metadata, () {
      var header = _visitor.pieces.build(() {
        _buildHeader();

        // Mixin application classes have ` = Superclass` after the declaration
        // name.
        _visitor.pieces.space();
        _visitor.pieces.token(equals);
        _visitor.pieces.space();
        _visitor.pieces.visit(superclass);
      });

      header = _buildClauses(header);

      _visitor.pieces.add(
        TypePiece(
          header,
          _visitor.tokenPiece(semicolon),
          bodyType: TypeBodyType.semicolon,
        ),
      );
    });
  }

  void _buildType(Piece Function() buildBody, TypeBodyType bodyType) {
    _visitor.pieces.withMetadata(_metadata, () {
      if (_namePart case PrimaryConstructorDeclaration constructor) {
        var header = _visitor.pieces.build(() {
          _buildHeader(includeParameters: false);
        });

        var parameters = _visitor.nodePiece(constructor.formalParameters);
        var clauses = [for (var clause in _clauses) clause.build(_visitor)];

        var bodyPiece = buildBody();

        _visitor.pieces.add(
          PrimaryTypePiece(header, parameters, clauses, bodyPiece, bodyType),
        );
      } else {
        var header = _buildClauses(_visitor.pieces.build(_buildHeader));
        var bodyPiece = buildBody();
        _visitor.pieces.add(TypePiece(header, bodyPiece, bodyType: bodyType));
      }
    });
  }

  /// Writes the leading keywords, name, and type parameters for the type.
  void _buildHeader({bool includeParameters = true}) {
    var space = false;
    for (var keyword in _keywords) {
      if (space) _visitor.pieces.space();
      _visitor.pieces.token(keyword);
      if (keyword != null) space = true;
    }

    switch (_namePart) {
      case null:
        _visitor.pieces.token(_name, spaceBefore: space);
        _visitor.pieces.visit(_typeParameters);

      case NameWithTypeParameters(:var typeName, :var typeParameters):
        _visitor.pieces.token(typeName, spaceBefore: space);
        _visitor.pieces.visit(typeParameters);

      case PrimaryConstructorDeclaration primary:
        _visitor.pieces.token(primary.constKeyword, spaceBefore: space);
        _visitor.pieces.token(primary.typeName, spaceBefore: true);
        _visitor.pieces.visit(primary.typeParameters);
        _visitor.pieces.visit(primary.constructorName);
        if (includeParameters) _visitor.pieces.visit(primary.formalParameters);
    }
  }

  /// If there are any clauses, wraps [header] in a [ClausePiece] for them.
  Piece _buildClauses(Piece header) {
    if (_clauses.isEmpty) return header;

    return ClausePiece(header, [
      for (var clause in _clauses) clause.build(_visitor),
    ], allowLeadingClause: _allowLeadingClause);
  }

  /// Builds a [Piece] for the body of an enum declaration with values but not
  /// members.
  ///
  /// Formats the constants like a list. This keeps the enum declaration on one
  /// line if it fits.
  Piece _buildNormalEnumBody(EnumBody body) {
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
  Piece _buildEnhancedEnumBody(EnumBody body) {
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
