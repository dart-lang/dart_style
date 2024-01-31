// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../piece/piece.dart';
import 'code_writer.dart';

/// A single possible line splitting solution.
///
/// Stores the states that each piece is set to and the resulting formatted
/// code and its cost.
class Solution implements Comparable<Solution> {
  /// The states that pieces have been bound to.
  ///
  /// Note that order that keys are inserted into this map is significant. When
  /// ordering solutions, we use the order that pieces are bound in here to
  /// break ties between solutions that otherwise have the same cost and
  /// overflow.
  final Map<Piece, State> _pieceStates;

  /// The amount of penalties applied based on the chosen line splits.
  final int cost;

  /// The formatted code.
  String get text => _text;
  late final String _text;

  /// Whether this score is for a valid solution or not.
  ///
  /// An invalid solution is one where a hard newline appears in a context
  /// where splitting isn't allowed. This is considered worse than any other
  /// solution.
  bool get isValid => _isValid;
  bool _isValid = true;

  /// Whether this solution can be expanded from to enqueue other solutions.
  ///
  /// This is generally `true`, but will be `false` if [isValid] is `false`
  /// and if the piece that forbid the unexpected newline was already bound by
  /// this solution so can't be chosen to have a different state in further
  /// expanded solutions.
  bool _canExpandSolution = true;

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
  Solution(Piece root, int pageWidth) : this._(root, pageWidth, 0, {});

  Solution._(Piece root, int pageWidth, this.cost, this._pieceStates) {
    var writer = CodeWriter(pageWidth, this);
    writer.format(root);

    var (text, nextPieceToExpand) = writer.finish();
    _text = text;
    _nextPieceToExpand = nextPieceToExpand;
  }

  /// The state this solution selects for [piece].
  ///
  /// If no state has been selected, defaults to the first state.
  State pieceState(Piece piece) => _pieceStates[piece] ?? piece.states.first;

  /// Whether [piece] has been bound to a state in this set.
  bool isBound(Piece piece) => _pieceStates.containsKey(piece);

  /// Increases the total overflow for this solution by [overflow].
  ///
  /// This should only be called by [CodeWriter].
  void addOverflow(int overflow) {
    _overflow += overflow;
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
    _isValid = false;

    // If the piece whose newline constraint was violated is already bound to
    // one state, then every solution derived from this one will also fail in
    // the same way, so discard the whole solution tree hanging off this one.
    if (isBound(piece)) _canExpandSolution = false;
  }

  /// When called on a [Solution] with some unselected piece states, chooses a
  /// piece and yields further solutions for each state that piece can have.
  List<Solution> expand(Piece root, int pageWidth) {
    // If this solution is invalid and can't lead to any valid solutions, don't
    // consider it.
    if (!_canExpandSolution) return const [];

    var expandPiece = _nextPieceToExpand;

    // If there is no piece that we can expand on this solution, it's a dead
    // end (or a winner).
    if (expandPiece == null) return const [];

    return [
      for (var state in expandPiece.states)
        if (_tryBind(root, pageWidth, expandPiece, state) case var solution?)
          solution
    ];
  }

  /// Attempts to extend this solution's piece states by binding [piece] to
  /// [state], taking into account any constraints pieces place on each other.
  ///
  /// Returns a new [Solution] with [piece] bound to [state] and any other
  /// pieces constrained by that choice bound to their constrained values
  /// (recursively). Returns `null` if a constraint conflicts with the already
  /// bound or pinned state for some piece.
  Solution? _tryBind(Piece root, int pageWidth, Piece piece, State state) {
    var conflict = false;
    var newStates = {..._pieceStates};
    var newCost = cost;

    void bind(Piece thisPiece, State thisState) {
      // If this piece is already pinned or bound to some other state, then the
      // solution doesn't make sense.
      var alreadyBound = thisPiece.pinnedState ?? newStates[thisPiece];
      if (alreadyBound != null && alreadyBound != thisState) {
        conflict = true;
        return;
      }

      newStates[thisPiece] = thisState;
      newCost += thisPiece.stateCost(thisState);

      // This piece may in turn place further constraints on others.
      thisPiece.applyConstraints(thisState, bind);
    }

    bind(piece, state);

    if (conflict) return null;

    return Solution._(root, pageWidth, newCost, newStates);
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
    var states = _pieceStates.keys
        .map((piece) => '$piece:${_pieceStates[piece]}')
        .join(' ');

    return [
      '\$$cost',
      if (overflow > 0) '($overflow over)',
      if (!isValid) '(invalid)',
      states,
    ].join(' ');
  }
}
