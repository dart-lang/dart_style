// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A list of "clauses" where each clause starts with a keyword and has a
/// comma-separated list of items under it.
///
/// Used for `show` and `hide` combinators in import and export directives, and
/// `extends`, `implements`, and `with` clauses in type declarations.
///
/// Clauses can be chained on one line if they all fit, like:
///
/// ```
/// import 'animals.dart' show Ant, Bat hide Cat, Dog;
/// ```
///
/// Or can split before all of the clauses, like:
///
/// ```
/// import 'animals.dart'
///     show Ant, Bat
///     hide Cat, Dog;
/// ```
///
/// They can also split before every item in any of the clauses. If they do so,
/// then the clauses must split too. So these are allowed:
///
/// ```
/// import 'animals.dart'
///     show
///         Ant,
///         Bat
///     hide Cat, Dog;
///
/// import 'animals.dart'
///     show Ant, Bat
///     hide
///         Cat,
///         Dog;
///
/// import 'animals.dart'
///     show
///         Ant,
///         Bat
///     hide
///         Cat,
///         Dog;
/// ```
///
/// But these are not:
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
class ClausesPiece extends Piece {
  final List<ClausePiece> _clauses;

  ClausesPiece(this._clauses);

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    // If any of the lists inside any of the clauses split, split at the
    // keywords too.
    writer.setAllowNewlines(state == State.split);
    for (var clause in _clauses) {
      writer.splitIf(state == State.split, indent: Indent.expression);
      writer.format(clause);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _clauses.forEach(callback);
  }

  @override
  String toString() => 'Clauses';
}

/// A keyword followed by a comma-separated list of items described by that
/// keyword.
class ClausePiece extends Piece {
  final Piece _keyword;

  /// The list of items in the clause.
  final List<Piece> _parts;

  ClausePiece(this._keyword, this._parts);

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_keyword);
    for (var part in _parts) {
      writer.splitIf(state == State.split, indent: Indent.expression);
      writer.format(part);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_keyword);
    _parts.forEach(callback);
  }

  @override
  String toString() => 'Clause';
}
