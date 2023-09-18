// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// An import or export directive.
///
/// Contains pieces for the keyword and URI, the optional `as` clause for
/// imports, the configurations (`if` clauses), and combinators (`show` and
/// `hide`).
class ImportPiece extends Piece {
  /// The main directive and its URI.
  final Piece directive;

  /// If the directive has `if` configurations, this is them.
  final Piece? configurations;

  /// The `as` clause for this directive.
  ///
  /// Null if this is not an import or it has no library prefix.
  final Piece? asClause;

  /// The piece for the `show` and/or `hide` combinators.
  final Piece? combinator;

  ImportPiece(
      this.directive, this.configurations, this.asClause, this.combinator);

  @override
  int get stateCount => 1;

  @override
  void format(CodeWriter writer, int state) {
    writer.format(directive);
    writer.formatOptional(configurations);
    writer.formatOptional(asClause);
    writer.formatOptional(combinator);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(directive);
    if (configurations case var configurations?) callback(configurations);
    if (asClause case var asClause?) callback(asClause);
    if (combinator case var combinator?) callback(combinator);
  }

  @override
  String toString() => 'Directive';
}

/// The combinator on a directive with only one combinator. It can be split:
///
///     // 0: All on one line:
///     import 'animals.dart' show Ant, Bat, Cat;
///
///     // 1: Split before the keyword:
///     import 'animals.dart'
///         show Ant, Bat, Cat;
///
///     // 2: Split before the keyword and each name:
///     import 'animals.dart'
///         show
///             Ant,
///             Bat,
///             Cat;
class OneCombinatorPiece extends Piece {
  final ImportCombinator combinator;

  OneCombinatorPiece(this.combinator);

  /// 0: No splits anywhere.
  /// 1: Split before combinator keyword.
  /// 2: Split before combinator keyword and before each name.
  @override
  int get stateCount => 3;

  @override
  void format(CodeWriter writer, int state) {
    combinator.format(writer, splitKeyword: state != 0, splitNames: state == 2);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    combinator.forEachChild(callback);
  }

  @override
  String toString() => '1Comb';
}

/// The combinators on a directive with two combinators. It can be split:
///
///     // 0: All on one line:
///     import 'animals.dart' show Ant, Bat hide Cat, Dog;
///
///     // 1: Wrap before each keyword:
///     import 'animals.dart'
///         show Ant, Bat
///         hide Cat, Dog;
///
///     // 2: Wrap before each keyword and split the first list of names:
///     import 'animals.dart'
///         show
///             Ant,
///             Bat
///         hide Cat, Dog;
///
///     // 3: Wrap before each keyword and split the second list of names:
///     import 'animals.dart'
///         show Ant, Bat
///         hide
///             Cat,
///             Dog;
///
///     // 4: Wrap before each keyword and split both lists of names:
///     import 'animals.dart'
///         show
///             Ant,
///             Bat
///         hide
///             Cat,
///             Dog;
///
/// These are not allowed:
///
///     // Wrap list but not keyword:
///     import 'animals.dart' show
///             Ant,
///             Bat
///         hide Cat, Dog;
///
///     // Wrap one keyword but not both:
///     import 'animals.dart'
///         show Ant, Bat hide Cat, Dog;
///
///     import 'animals.dart' show Ant, Bat
///         hide Cat, Dog;
///
/// This ensures that when any wrapping occurs, the keywords are always at
/// the beginning of the line.
class TwoCombinatorPiece extends Piece {
  final List<ImportCombinator> combinators;

  TwoCombinatorPiece(this.combinators);

  @override
  int get stateCount => 5;

  @override
  void format(CodeWriter writer, int state) {
    assert(combinators.length == 2);

    combinators[0].format(writer,
        splitKeyword: state != 0, splitNames: state == 2 || state == 4);
    combinators[1].format(writer,
        splitKeyword: state != 0, splitNames: state == 3 || state == 4);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    for (var combinator in combinators) {
      combinator.forEachChild(callback);
    }
  }

  @override
  String toString() => '2Comb';
}

/// A single `show` or `hide` combinator within an import or export directive.
class ImportCombinator {
  /// The `show` or `hide` keyword.
  final Piece keyword;

  /// The names being shown or hidden.
  final List<Piece> names = [];

  ImportCombinator(this.keyword);

  void format(CodeWriter writer,
      {required bool splitKeyword, required bool splitNames}) {
    writer.setAllowNewlines(true);
    writer.splitIf(splitKeyword, indent: Indent.expression);
    writer.setAllowNewlines(splitKeyword);
    writer.format(keyword);
    for (var name in names) {
      writer.splitIf(splitNames, indent: Indent.combinatorName);
      writer.setAllowNewlines(splitNames);
      writer.format(name);
    }
  }

  void forEachChild(void Function(Piece piece) callback) {
    callback(keyword);
    names.forEach(callback);
  }
}
