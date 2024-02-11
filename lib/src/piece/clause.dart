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
///     import 'animals.dart' show Ant, Bat hide Cat, Dog;
///
/// Or can split before all of the clauses, like:
///
///     import 'animals.dart'
///         show Ant, Bat
///         hide Cat, Dog;
///
/// They can also split before every item in any of the clauses. If they do so,
/// then the clauses must split too. So these are allowed:
///
///     import 'animals.dart'
///         show
///             Ant,
///             Bat
///         hide Cat, Dog;
///
///     import 'animals.dart'
///         show Ant, Bat
///         hide
///             Cat,
///             Dog;
///
///     import 'animals.dart'
///         show
///             Ant,
///             Bat
///         hide
///             Cat,
///             Dog;
///
/// But these are not:
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
/// This ensures that when any wrapping occurs, the keywords are always at the
/// beginning of the line.
class ClausesPiece extends Piece {
  /// State where we split between the clauses but not before the first one.
  static const State _betweenClauses = State(1);

  final List<ClausePiece> _clauses;

  /// If `true`, then we're allowed to split between the clauses without
  /// splitting before the first one too.
  ///
  /// This is used for class declarations where the `extends` clauses is treated
  /// a little specially because it's a deeper coupling to the class and so we
  /// want it to stay on the top line even if the other clauses split, like:
  ///
  ///     class BaseClass extends Derived
  ///         implements OtherThing {
  ///       ...
  ///     }
  final bool _allowLeadingClause;

  ClausesPiece(this._clauses, {bool allowLeadingClause = false})
      : _allowLeadingClause = allowLeadingClause;

  @override
  List<State> get additionalStates =>
      [if (_allowLeadingClause) _betweenClauses, State.split];

  @override
  void format(CodeWriter writer, State state) {
    writer.pushIndent(Indent.expression);

    for (var clause in _clauses) {
      if (_allowLeadingClause && clause == _clauses.first) {
        // Before the leading clause, only split when in the fully split state.
        // A split inside the first clause forces a split before the keyword.
        writer.splitIf(state == State.split);
        writer.pushAllowNewlines(state == State.split);
      } else {
        // For the other clauses (or if there is no leading one), split in the
        // fully split state and any split inside and clause forces all of them
        // to split.
        writer.pushAllowNewlines(state != State.unsplit);
        writer.splitIf(state != State.unsplit);
      }

      writer.format(clause);

      writer.popAllowNewlines();
    }

    writer.popIndent();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _clauses.forEach(callback);
  }
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
    // If any of the parts inside the clause split, split the list.
    writer.pushAllowNewlines(state != State.unsplit);
    writer.pushIndent(Indent.expression);

    writer.format(_keyword);
    for (var part in _parts) {
      writer.splitIf(state == State.split);
      writer.format(part);
    }

    writer.popIndent();
    writer.popAllowNewlines();
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_keyword);
    _parts.forEach(callback);
  }
}
