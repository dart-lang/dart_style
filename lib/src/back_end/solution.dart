// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../piece/piece.dart';
import 'code_writer.dart';
import 'solution_cache.dart';

/// A single possible set of formatting choices.
///
/// Each solution binds some number of [Piece]s in the piece tree to [State]s.
/// (Any pieces whose states are not bound are treated as having a default
/// unsplit state.)
///
/// Given that set of states, we can create a [CodeWriter] and give that to all
/// of the pieces in the tree so they can format themselves. That in turn
/// yields a total number of overflow characters, cost, and formatted output,
/// which are all stored here.
class Solution implements Comparable<Solution> {
  /// The states that pieces have been bound to.
  ///
  /// Note that order that keys are inserted into this map is significant. When
  /// ordering solutions, we use the order that pieces are bound in here to
  /// break ties between solutions that otherwise have the same cost and
  /// overflow.
  final Map<Piece, State> _pieceStates;

  /// The amount of penalties applied based on the chosen line splits.
  int get cost => _cost;
  int _cost;

  /// The formatted code.
  String get text => _text;
  late final String _text;

  /// Whether this score is for a valid solution or not.
  ///
  /// An invalid solution is one where a hard newline appears in a context
  /// where splitting isn't allowed. This is considered worse than any other
  /// solution.
  bool get isValid => _invalidPiece == null;

  /// The piece that forbid newlines when an invalid newline was written, or
  /// `null` if no invalid newline has occurred.
  Piece? _invalidPiece;

  /// The total number of characters that do not fit inside the page width.
  int get overflow => _overflow;
  int _overflow = 0;

  /// The unsolved piece in this solution that should be expanded next to
  /// produce new more refined solutions, if there is one.
  ///
  /// The tree of possible solutions is combinatorial in the number of pieces
  /// and exponential in the number of states those pieces can take. We can't
  /// afford to brute force explore the whole tree, even with the optimization
  /// that we stop as soon as we find a solution with no overflow.
  ///
  /// Most possible solutions add unnecessary splits in regions of the code
  /// that already fit within the page width. Exploring those is wasted time.
  /// To avoid that, we rely on a couple of insights:
  ///
  /// First, the solver treats any piece with an unselected state as being
  /// unsplit. This means that refining a solution always takes a piece that is
  /// unsplit and makes it split more. That monotonically increases the cost,
  /// but may help fit the solution inside the page.
  ///
  /// Therefore, we don't want to select states for most pieces. Only pieces
  /// that need to split in order to find a solution that fits in the page
  /// width or that are necessary because the unsplit state is invalid. (The
  /// latter usually means a line comment or statement occurs inside the piece.)
  ///
  /// So we skip past any pieces that aren't on overflowing lines or on lines
  /// whose newline led to an invalid solution. Further, it's also the case
  /// that splitting an earlier pieces will often reshuffle the formatting of
  /// much of the code following it.
  ///
  /// Thus we only worry about the *first* unsolved piece on the first
  /// problematic line when expanding. If selecting states for that piece still
  /// doesn't help, the solver will work its way through later pieces from those
  /// subsequenct partial solutions.
  ///
  /// This lets us efficiently skip through almost all of the pieces that don't
  /// need to be touched in order to find a valid solution.
  ///
  /// If this is `null`, then there are no further solutions to generate from
  /// this one. It's either a dead end or a winner.
  late final Piece? _nextPieceToExpand;

  /// The offset in [text] where the selection starts, or `null` if there is
  /// no selection.
  int? get selectionStart => _selectionStart;
  int? _selectionStart;

  /// The offset in [text] where the selection ends, or `null` if there is
  /// no selection.
  int? get selectionEnd => _selectionEnd;
  int? _selectionEnd;

  /// Creates a new [Solution] with no pieces set to any state (which
  /// implicitly means they have state [State.unsplit] unless they're pinned to
  /// another state).
  factory Solution(SolutionCache cache, Piece root,
      {required int pageWidth, required int leadingIndent, State? rootState}) {
    var pieceStates = <Piece, State>{};
    var cost = 0;

    // If we're formatting a subtree of a larger Piece tree that binds [root]
    // to [rootState], then bind it in this solution too.
    if (rootState != null) {
      var additionalCost = _tryBind(pieceStates, root, rootState);

      // Binding should always succeed since we should only get here when
      // formatting a subtree whose surrounding Solution successfully bound
      // this piece to this state.
      cost += additionalCost!;
    }

    return Solution._(cache, root, pageWidth, leadingIndent, cost, pieceStates);
  }

  Solution._(SolutionCache cache, Piece root, int pageWidth, int leadingIndent,
      this._cost, this._pieceStates) {
    var writer = CodeWriter(pageWidth, leadingIndent, cache, this);
    writer.format(root);

    var (text, nextPieceToExpand) = writer.finish();
    _text = text;
    _nextPieceToExpand = nextPieceToExpand;
  }

  /// The state that [piece] is pinned to or that this solution selects.
  ///
  /// If no state has been selected, defaults to the first state.
  State pieceState(Piece piece) => pieceStateIfBound(piece) ?? State.unsplit;

  /// The state that [piece] is pinned to or that this solution selects.
  ///
  /// If no state has been selected, returns `null`.
  State? pieceStateIfBound(Piece piece) =>
      piece.pinnedState ?? _pieceStates[piece];

  /// Whether [piece] has been bound to a state in this set (or is pinned).
  bool isBound(Piece piece) =>
      piece.pinnedState != null || _pieceStates.containsKey(piece);

  /// Increases the total overflow for this solution by [overflow].
  ///
  /// This should only be called by [CodeWriter].
  void addOverflow(int overflow) {
    _overflow += overflow;
  }

  /// Apply the overflow, cost, and bound states from [subtreeSolution] to this
  /// solution.
  ///
  /// This is called when a subtree of a Piece tree is solved separately and
  /// the resulting solution is being merged with this one.
  void mergeSubtree(Solution subtreeSolution) {
    _overflow += subtreeSolution._overflow;

    // Add the subtree's bound pieces to this one. Make sure to not double
    // count costs for pieces that are already bound in this one.
    subtreeSolution._pieceStates.forEach((piece, state) {
      _pieceStates.putIfAbsent(piece, () {
        _cost += piece.stateCost(state);
        return state;
      });
    });
  }

  /// Sets [selectionStart] to be [start] code units into the output.
  ///
  /// This should only be called by [CodeWriter].
  void startSelection(int start) {
    assert(_selectionStart == null);
    _selectionStart = start;
  }

  /// Sets [selectionEnd] to be [end] code units into the output.
  ///
  /// This should only be called by [CodeWriter].
  void endSelection(int end) {
    assert(_selectionEnd == null);
    _selectionEnd = end;
  }

  /// Mark this solution as having a newline where none is permitted by [piece]
  /// and is thus not a valid solution.
  ///
  /// This should only be called by [CodeWriter].
  void invalidate(Piece piece) {
    _invalidPiece = piece;
  }

  /// Derives new potential solutions from this one by binding
  /// [_nextPieceToExpand] to all of its possible states.
  ///
  /// If there is no potential piece to expand, or all attempts to expand it
  /// fail, returns an empty list.
  List<Solution> expand(SolutionCache cache, Piece root,
      {required int pageWidth, required int leadingIndent}) {
    // If the piece whose newline constraint was violated is already bound to
    // one state, then every solution derived from this one will also fail in
    // the same way, so discard the whole solution tree hanging off this one.
    if (_invalidPiece case var piece? when isBound(piece)) return const [];

    var expandPiece = _nextPieceToExpand;

    // If there is no piece that we can expand on this solution, it's a dead
    // end (or a winner).
    if (expandPiece == null) return const [];

    // TODO(perf): If `_invalidPiece == expandPiece`, then we know that the
    // first state leads to an invalid solution, so there's no point in trying
    // to expand to a solution that binds `expandPiece` to
    // `expandPiece.states[0]`. We should be able to do:
    //
    //     Iterable<State> states = expandPiece.states;
    //     if (_invalidPiece == expandPiece) {
    //       print('skip $expandPiece ${states.first}');
    //       states = states.skip(1);
    //     }
    //
    // And then use `states` below. But when I tried that, it didn't seem to
    // make any noticeable performance difference on the one pathological
    // example I tried. Leaving this here as a TODO to investigate more when
    // there are other benchmarks we can try.
    var solutions = <Solution>[];

    // For each state that the expanding piece can be in, create a new solution
    // that inherits all of the bindings of this one, and binds the expanding
    // piece to that state (along with any further pieces constrained by that
    // one).
    for (var state in expandPiece.states) {
      var newStates = {..._pieceStates};

      var additionalCost = _tryBind(newStates, expandPiece, state);

      // Discard the solution if we hit a constraint violation.
      if (additionalCost == null) continue;

      solutions.add(Solution._(cache, root, pageWidth, leadingIndent,
          cost + additionalCost, newStates));
    }

    return solutions;
  }

  /// Compares two solutions where a more desirable solution comes first.
  ///
  /// For performance, we want to stop checking solutions as soon as we find
  /// the best one. Best means the fewest overflow characters and the lowest
  /// code.
  @override
  int compareTo(Solution other) {
    // Even though overflow is "worse" than cost, we order in terms of cost
    // because a solution with overflow may lead to a low-cost solution without
    // overflow, so we want to explore in cost order.
    if (cost != other.cost) return cost.compareTo(other.cost);

    if (overflow != other.overflow) return overflow.compareTo(other.overflow);

    // If all else is equal, prefer lower states in earlier bound pieces.
    for (var piece in _pieceStates.keys) {
      var thisState = pieceState(piece);
      var otherState = other.pieceState(piece);
      if (thisState != otherState) return thisState.compareTo(otherState);
    }

    return 0;
  }

  @override
  String toString() {
    var states = [
      for (var MapEntry(key: piece, value: state) in _pieceStates.entries)
        if (piece.additionalStates.isNotEmpty && piece.pinnedState == null)
          '$piece$state'
    ];

    return [
      '\$$cost',
      if (overflow > 0) '($overflow over)',
      if (!isValid) '(invalid)',
      states.join(' '),
    ].join(' ').trim();
  }

  /// Attempts to add a binding from [piece] to [state] in [boundStates], and
  /// then adds any further bindings from constraints that [piece] applies to
  /// its children, recursively.
  ///
  /// This may fail if [piece] is already bound to a different [state], or if
  /// any constrained pieces are bound to different states.
  ///
  /// If successful, returns the additional cost required to bind [piece] to
  /// [state] (along with any other applied constrained pieces). Otherwise,
  /// returns `null` to indicate failure.
  static int? _tryBind(
      Map<Piece, State> boundStates, Piece piece, State state) {
    var success = true;
    var additionalCost = 0;

    void bind(Piece thisPiece, State thisState) {
      // If we've already failed from a previous sibling's constraint violation,
      // early out.
      if (!success) return;

      // Apply the new binding if it doesn't conflict with an existing one.
      switch (thisPiece.pinnedState ?? boundStates[thisPiece]) {
        case null:
          // Binding a unbound piece to a state.
          additionalCost += thisPiece.stateCost(thisState);
          boundStates[thisPiece] = thisState;

          // This piece may in turn place further constraints on others.
          thisPiece.applyConstraints(thisState, bind);
        case var alreadyBound when alreadyBound != thisState:
          // Already bound to a different state, so there's a conflict.
          success = false;
        default:
          break; // Already bound to the same state, so nothing to do.
      }
    }

    bind(piece, state);

    return success ? additionalCost : null;
  }
}
