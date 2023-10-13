// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// An import or export directive and its `show` and `hide` combinators.
///
/// Contains pieces for the keyword and URI, the optional `as` clause for
/// imports, and the configurations (`if` clauses).
///
/// Combinators can be split like so:
///
/// [State.initial] All on one line:
///
/// ```
/// import 'animals.dart' show Ant, Bat hide Cat, Dog;
/// ```
///
/// [_beforeCombinators] Wrap before each keyword:
///
/// ```
/// import 'animals.dart'
///     show Ant, Bat
///     hide Cat, Dog;
/// ```
///
/// [_firstCombinator] Wrap before each keyword and split the first list of
/// names (only used when there are multiple combinators):
///
/// ```
/// import 'animals.dart'
///     show
///         Ant,
///         Bat
///     hide Cat, Dog;
/// ```
///
/// [_secondCombinator]: Wrap before each keyword and split the second list of
/// names (only used when there are multiple combinators):
///
/// ```
/// import 'animals.dart'
///     show Ant, Bat
///     hide
///         Cat,
///         Dog;
/// ```
///
/// [State.split] Wrap before each keyword and split both lists of names:
///
/// ```
/// import 'animals.dart'
///     show
///         Ant,
///         Bat
///     hide
///         Cat,
///         Dog;
/// ```
///
/// These are not allowed:
///
/// ```
/// // Wrap list but not keyword:
/// import 'animals.dart' show
///         Ant,
///         Bat
///     hide Cat, Dog;
///
/// // Wrap one keyword but not both:
/// import 'animals.dart'
///     show Ant, Bat hide Cat, Dog;
///
/// import 'animals.dart' show Ant, Bat
///     hide Cat, Dog;
/// ```
///
/// This ensures that when any wrapping occurs, the keywords are always at the
/// beginning of the line.
class ImportPiece extends Piece {
  /// Split before combinator keywords.
  static const _beforeCombinators = State(1);

  /// Split before each name in the first combinator.
  static const _firstCombinator = State(2);

  /// Split before each name in the second combinator.
  static const _secondCombinator = State(3);

  /// The main directive and its URI.
  final Piece _directive;

  /// If the directive has `if` configurations, this is them.
  final Piece? _configurations;

  /// The `as` clause for this directive.
  ///
  /// Null if this is not an import or it has no library prefix.
  final Piece? _asClause;

  final List<ImportCombinator> _combinators;

  ImportPiece(this._directive, this._configurations, this._asClause,
      this._combinators) {
    assert(_combinators.length <= 2);
  }

  @override
  List<State> get states => [
        _beforeCombinators,
        if (_combinators.length > 1) ...[
          _firstCombinator,
          _secondCombinator,
        ],
        State.split
      ];

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_directive);
    writer.formatOptional(_configurations);
    writer.formatOptional(_asClause);

    if (_combinators.isNotEmpty) {
      _combinators[0].format(writer,
          splitKeyword: state != State.initial,
          splitNames: state == _firstCombinator || state == State.split);
    }

    if (_combinators.length > 1) {
      _combinators[1].format(writer,
          splitKeyword: state != State.initial,
          splitNames: state == _secondCombinator || state == State.split);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_directive);
    if (_configurations case var configurations?) callback(configurations);
    if (_asClause case var asClause?) callback(asClause);

    for (var combinator in _combinators) {
      combinator.forEachChild(callback);
    }
  }

  @override
  String toString() => 'Import';
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
