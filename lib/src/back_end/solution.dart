// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../piece/piece.dart';
import 'code_writer.dart';

/// A possibly incomplete set of selected states for a set of pieces being
/// solved.
class PieceStateSet {
  // TODO(perf): Looking up and expanding the set of chunk states was a
  // performance bottleneck in the old line splitter. If that turns out to be
  // true here, then consider a faster representation for this list and the
  // subsequent map field.
  /// The in-order flattened list of all pieces being solved.
  ///
  /// This doesn't include pieces like text that have only a single value since
  /// there's nothing to solve for them.
  final List<Piece> _pieces;

  final Map<Piece, State> _pieceStates;

  /// Creates a new [PieceStateSet] with no pieces set to any state (which
  /// implicitly means they have state 0).
  PieceStateSet(this._pieces) : _pieceStates = {};

  PieceStateSet._(this._pieces, this._pieceStates);

  /// The state this solution selects for [piece].
  ///
  /// If no state has been selected, defaults to the first state.
  State pieceState(Piece piece) => _pieceStates[piece] ?? piece.states.first;

  /// Whether [piece] has been bound to a state in this set.
  bool isBound(Piece piece) => _pieceStates.containsKey(piece);

  /// Creates a clone of this state with [piece] bound to [state].
  PieceStateSet cloneWith(Piece piece, State state) {
    return PieceStateSet._(_pieces, {..._pieceStates, piece: state});
  }

  @override
  String toString() {
    return _pieces.map((piece) {
      var state = _pieceStates[piece];
      var stateLabel = state == null ? '?' : '$state';
      return '$piece:$stateLabel';
    }).join(' ');
  }
}

/// A single possible line splitting solution.
///
/// Stores the states that each piece is set to and the resulting formatted
/// code and its cost.
class Solution implements Comparable<Solution> {
  /// The states the pieces have been set to in this solution.
  final PieceStateSet _state;

  /// The formatted code.
  final String text;

  /// Whether this score is for a valid solution or not.
  ///
  /// An invalid solution is one where a hard newline appears in a context
  /// where splitting isn't allowed. This is considered worse than any other
  /// solution.
  final bool isValid;

  /// The number of characters that do not fit inside the page width.
  final int overflow;

  /// The amount of penalties applied based on the chosen line splits.
  final int cost;

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
  final Piece? _nextPieceToExpand;

  /// The offset in [text] where the selection starts, or `null` if there is
  /// no selection.
  final int? selectionStart;

  /// The offset in [text] where the selection ends, or `null` if there is
  /// no selection.
  final int? selectionEnd;

  factory Solution.initial(Piece root, int pageWidth, List<Piece> pieces) {
    return Solution._(root, pageWidth, PieceStateSet(pieces));
  }

  factory Solution._(Piece root, int pageWidth, PieceStateSet state) {
    var writer = CodeWriter(pageWidth, state);
    writer.format(root);
    return writer.finish();
  }

  Solution(this._state, this.text, this.selectionStart, this.selectionEnd,
      this._nextPieceToExpand,
      {required this.overflow, required this.cost, required this.isValid});

  /// When called on a [Solution] with some unselected piece states, chooses a
  /// piece and yields further solutions for each state that piece can have.
  List<Solution> expand(Piece root, int pageWidth) {
    if (_nextPieceToExpand case var piece?) {
      return [
        for (var state in piece.states)
          Solution._(root, pageWidth, _state.cloneWith(piece, state))
      ];
    }

    // No piece we can expand.
    return const [];
  }

  /// Compares two solutions where a more desirable solution comes first.
  ///
  /// For performance, we want to stop checking solutions as soon as we find
  /// the best one. Best means the fewest overflow characters and the lowest
  /// code.
  @override
  int compareTo(Solution other) {
    // TODO(perf): This check is necessary to not make some of the tests not
    // timeout, but I'm not sure why. Investigate what this does and if it's
    // still necessary once other optimizations are in place.
    // An invalid solution is worse than all others.
    if (!isValid) return 1;
    if (!other.isValid) return -1;

    // Even though overflow is "worse" than cost, we order in terms of cost
    // because a solution with overflow may lead to a low-cost solution without
    // overflow, so we want to explore in cost order.
    if (cost != other.cost) return cost.compareTo(other.cost);

    if (overflow != other.overflow) return overflow.compareTo(other.overflow);

    // Should be solving the same set of pieces.
    assert(_state._pieces.length == other._state._pieces.length);

    // If all else is equal, prefer lower states in earlier pieces.
    // TODO(tall): This might not be needed once piece scoring is more
    // sophisticated.
    for (var i = 0; i < _state._pieces.length; i++) {
      var piece = _state._pieces[i];
      var thisState = _state.pieceState(piece);
      var otherState = other._state.pieceState(piece);
      if (thisState != otherState) return thisState.compareTo(otherState);
    }

    return 0;
  }

  @override
  String toString() {
    return [
      '\$$cost',
      if (overflow > 0) '($overflow over)',
      if (!isValid) '(invalid)',
      '$_state',
    ].join(' ');
  }
}
