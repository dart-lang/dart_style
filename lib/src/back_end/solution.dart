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

  final Map<Piece, int> _pieceStates;

  /// Creates a new [PieceStateSet] with no pieces set to any state (which
  /// implicitly means they have state 0).
  PieceStateSet(this._pieces) : _pieceStates = {};

  PieceStateSet._(this._pieces, this._pieceStates);

  /// The state this solution selects for [piece].
  int pieceState(Piece piece) => _pieceStates[piece] ?? 0;

  /// Gets the first piece that doesn't have a state selected yet, or `null` if
  /// all pieces have selected states.
  Piece? firstUnsolved() {
    // TODO(perf): This may be slow. Could store the index at construction time.
    for (var piece in _pieces) {
      if (!_pieceStates.containsKey(piece)) {
        return piece;
      }
    }

    return null;
  }

  /// Creates a clone of this state with [piece] bound to [state].
  PieceStateSet cloneWith(Piece piece, int state) {
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

  /// The score resulting from the selected piece states.
  final Score score;

  factory Solution(Piece root, int pageWidth, PieceStateSet state) {
    var writer = CodeWriter(pageWidth, state);
    writer.format(root);
    var (text, score) = writer.finish();
    return Solution._(state, text, score);
  }

  Solution._(this._state, this.text, this.score);

  /// When called on a [Solution] with some unselected piece states, chooses a
  /// piece and yields further solutions for each state that piece can have.
  List<Solution> expand(Piece root, int pageWidth) {
    var piece = _state.firstUnsolved();
    if (piece == null) return const [];

    var result = <Solution>[];
    for (var i = 0; i < piece.stateCount; i++) {
      var solution = Solution(root, pageWidth, _state.cloneWith(piece, i));
      result.add(solution);
    }

    return result;
  }

  /// Compares two solutions where a more desirable solution comes first.
  ///
  /// For performance, we want to stop checking solutions as soon as we find
  /// the best one. Best means the fewest overflow characters and the lowest
  /// code.
  @override
  int compareTo(Solution other) {
    var scoreComparison = score.compareTo(other.score);
    if (scoreComparison != 0) return scoreComparison;

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
  String toString() => '$score $_state';
}

class Score implements Comparable<Score> {
  // TODO(tall): Should this actually be part of scoring? Do we want to use
  // validity to determine how we order solutions to explore?
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

  Score({required this.isValid, required this.overflow, required this.cost});

  @override
  int compareTo(Score other) {
    // All invalid solutions are equal.
    if (!isValid && !other.isValid) return 0;

    // We are looking for *lower* costs and overflows, so an invalid score is
    // considered higher or after all others.
    if (!isValid) return 1;
    if (!other.isValid) return -1;

    // Overflow is always penalized more than line splitting cost.
    if (overflow != other.overflow) return overflow.compareTo(other.overflow);

    return cost.compareTo(other.cost);
  }

  @override
  String toString() {
    return [
      '\$$cost',
      if (overflow > 0) '($overflow over)',
      if (!isValid) '(invalid)'
    ].join(' ');
  }
}
