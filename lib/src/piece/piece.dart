// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../profile.dart';

typedef Constrain = void Function(Piece other, State constrainedState);

/// Base class for the formatter's internal representation used for line
/// splitting.
///
/// We visit the source AST and convert it to a tree of [Piece]s. This tree
/// roughly follows the AST but includes comments and is optimized for
/// formatting and line splitting. The final output is then determined by
/// deciding which pieces split and how.
abstract class Piece {
  /// The ordered list of all possible ways this piece could split.
  ///
  /// Piece subclasses should override this if they support being split in
  /// multiple different ways.
  ///
  /// Each piece determines what each [State] in the list represents, including
  /// the automatically included [State.unsplit]. The list returned by this
  /// function should be sorted so that earlier states in the list compare less
  /// than later states.
  List<State> get additionalStates => const [];

  /// If this piece has been pinned to a specific state, that state.
  ///
  /// This is used when a piece which otherwise supports multiple ways of
  /// splitting should be eagerly constrained to a specific splitting choice
  /// because of the context where it appears. For example, if conditional
  /// expressions are nested, then all of them are forced to split because it's
  /// too hard to read nested conditionals all on one line. We can express that
  /// by pinning the Piece used for a conditional expression to its split state
  /// when surrounded by or containing other conditionals.
  State? get pinnedState => _pinnedState;
  State? _pinnedState;

  /// Whether this piece or any of its children contain an explicit mandatory
  /// newline.
  ///
  /// This is lazily computed and cached for performance, so should only be
  /// accessed after all of the piece's children are known.
  late final bool containsHardNewline = calculateContainsHardNewline();

  bool calculateContainsHardNewline() {
    var anyHasNewline = false;

    forEachChild((child) {
      anyHasNewline |= child.containsHardNewline;
    });

    return anyHasNewline;
  }

  /// The total number of characters of content in this piece and all of its
  /// children.
  ///
  /// This is lazily computed and cached for performance, so should only be
  /// accessed after all of the piece's children are known.
  late final int totalCharacters = calculateTotalCharacters();

  int calculateTotalCharacters() {
    var total = 0;

    forEachChild((child) {
      total += child.totalCharacters;
    });

    return total;
  }

  Piece() {
    Profile.count('create Piece');
  }

  /// Apply any constraints that this piece places on other pieces when this
  /// piece is bound to [state].
  ///
  /// A piece class can override this. For any child piece that it wants to
  /// constrain when this piece is in [state], call [constrain] and pass in the
  /// child piece and the state that child should be constrained to.
  void applyConstraints(State state, Constrain constrain) {}

  /// Whether the [child] of this piece should be allowed to contain newlines
  /// (directly or transitively) when this piece is in [state].
  bool allowNewlineInChild(State state, Piece child) => true;

  /// Whether this piece contains a newline when this piece is in [state].
  ///
  /// This should only return `true` if the piece will *always* write at least
  /// one newline -- either itself or one of its children -- when in this state.
  /// If a piece may contain a newline or may not in some state, this should
  /// return `false`.
  ///
  /// By default, we assume that any piece not in [State.unsplit] or that has a
  /// hard newline will contain a newline.
  bool containsNewline(State state) =>
      state != State.unsplit || containsHardNewline;

  /// Given that this piece is in [state], use [writer] to produce its formatted
  /// output.
  void format(CodeWriter writer, State state);

  /// Invokes [callback] on each piece contained in this piece.
  void forEachChild(void Function(Piece piece) callback);

  /// If the piece can determine that it will always end up in a certain state
  /// given [pageWidth] and size metrics returned by calling
  /// [containsHardNewline] and [totalCharacters] on its children, then returns
  /// that [State].
  ///
  /// For example, a series of infix operators wider than a page will always
  /// split one per operator. If we can determine this eagerly just based on
  /// the size of the children and the page width, then we can pin the Piece to
  /// that State. That in turn heavily prunes the search space that the [Solver]
  /// is exploring. In practice, for large expressions, many of the outermost
  /// Pieces can be eagerly pinned to their fully split state. That avoids the
  /// Solver wasting a lot of time trying in vain to pack those outer Pieces
  /// into unsplit states when it's obvious just from the size of their contents
  /// that they'll have to split.
  ///
  /// If it's not possible to determine whether a piece will split from its
  /// metrics, this returns `null`.
  ///
  /// This is purely an optimization: Running the [Solver] without ever calling
  /// this and pinning the resulting [State] should yield the same formatting.
  /// It is up to the [Piece] subclasses overriding this to ensure that they
  /// only return a non-`null` [State] if the piece really would always be
  /// solved to the returned state given its children.
  State? fixedStateForPageWidth(int pageWidth) => null;

  /// The cost that this piece should apply to the solution when in [state].
  ///
  /// This is usually just the state's cost, but some pieces may want to tweak
  /// the cost in certain circumstances.
  // TODO(tall): Given that we have this API now, consider whether it makes
  // sense to remove the cost field from State entirely.
  int stateCost(State state) => state.cost;

  /// Forces this piece to always use [state].
  void pin(State state) {
    // Only pin a piece once. This can happen if the contents of an
    // interpolation expression (which are pinned to prevent splitting) are
    // large enough for [fixedStateForPageWidth()] to also try to pin it to its
    // fully split state.
    if (_pinnedState != null) return;

    _pinnedState = state;

    // If this piece's pinned state constrains any child pieces, pin those too,
    // recursively.
    applyConstraints(state, (other, constrainedState) {
      other.pin(constrainedState);
    });
  }

  /// Pin the piece to whatever state is needed to prevent it from splitting.
  void preventSplit() {
    // For most pieces, the initial state does it.
    pin(State.unsplit);
  }

  /// All of the transitive children of this piece (including the piece itself)
  /// that have more than state.
  ///
  /// This calculated and cached because it's faster than traversing the child
  /// tree and having to skip past all of the stateless [AdjacentPiece],
  /// [SpacePiece], [SequencePiece], etc.
  late final List<Piece> statefulOffspring = _calculateStatelessOffspring();

  List<Piece> _calculateStatelessOffspring() {
    // TODO(rnystrom): Traversing and storing the transitive list of stateless
    // offspring at every level of the Piece tree might be slow. Is it? If so,
    // is there a faster way to propagate constraints to the relevant parts of
    // the subtree?
    var result = <Piece>[];
    void traverse(Piece piece) {
      if (piece.additionalStates.isNotEmpty) result.add(piece);
      piece.forEachChild(traverse);
    }

    traverse(this);
    return result;
  }

  /// The name of this piece as it appears in debug output.
  ///
  /// By default, this is the class's name with `Piece` removed.
  String get debugName => runtimeType.toString().replaceAll('Piece', '');

  @override
  String toString() => '$debugName${_pinnedState ?? ''}';
}

/// A state that a piece can be in.
///
/// Each state identifies one way that a piece can be split into multiple lines.
/// Each piece determines how its states are interpreted.
class State implements Comparable<State> {
  static const unsplit = State(0, cost: 0);

  /// The maximally split state a piece can be in.
  ///
  /// The value here is somewhat arbitrary. It just needs to be larger than
  /// any other value used by any [Piece] that uses this [State].
  static const split = State(255);

  final int _value;

  /// How much a solution is penalized when this state is chosen.
  final int cost;

  const State(this._value, {this.cost = 1});

  @override
  int compareTo(State other) => _value.compareTo(other._value);

  @override
  String toString() => '◦$_value';
}
