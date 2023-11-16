// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:collection/collection.dart';

import '../debug.dart' as debug;
import '../piece/piece.dart';
import 'solution.dart';

/// Selects states for each piece in a tree of pieces to find the best set of
/// line splits that minimizes overflow characters and line splitting costs.
///
/// This problem is combinatorial for the number of pieces and each of their
/// possible states, so it isn't feasible to brute force. There are a few
/// techniques we use to avoid that:
///
/// -   The initial state for each piece has no line splits or only mandatory
///     ones. Thus, it tries solutions with a minimum number of line splits
///     first.
///
/// -   Solutions are explored in priority order. We explore solutions with the
///     the lowest cost first. This way, as soon as we find a solution with no
///     overflow characters, we know it will be the best solution and can stop.
///
/// -   When selecting states for pieces to expand solutions, we only look at
///     pieces in the first line containing overflow characters or invalid
///     newlines. See [Solution._livePieces] for more details.
// TODO(perf): At some point, we may also want to do memoization of previously
// formatted Piece subtrees.
class Solver {
  final int _pageWidth;

  final PriorityQueue<Solution> _queue = PriorityQueue();

  Solver(this._pageWidth);

  /// Finds the best set of line splits for [piece] and returns the resulting
  /// formatted code.
  Solution format(Piece piece) {
    // Collect all of the pieces with states that can be selected.
    var unsolvedPieces = <Piece>[];

    void traverse(Piece piece) {
      // We don't need to worry about selecting pieces that have only one state.
      if (piece.states.length > 1) unsolvedPieces.add(piece);
      piece.forEachChild(traverse);
    }

    traverse(piece);

    return _solve(piece, unsolvedPieces);
  }

  /// Finds the best solution for the piece tree starting at [root] with
  /// selectable [pieces].
  Solution _solve(Piece root, List<Piece> pieces) {
    var solution = Solution.initial(root, _pageWidth, pieces);
    _queue.add(solution);

    // The lowest cost solution found so far that does overflow.
    var best = solution;

    while (_queue.isNotEmpty) {
      var solution = _queue.removeFirst();

      if (debug.traceSolver) {
        debug.log(debug.bold(solution));
        debug.log(solution.text);
        debug.log('');
      }

      // Since we process the solutions from lowest cost up, as soon as we find
      // a valid one that fits, it's the best.
      if (solution.isValid) {
        if (solution.overflow == 0) return solution;

        if (solution.overflow < best.overflow) best = solution;
      }

      // Otherwise, try to expand the solution to explore different splitting
      // options.
      for (var expanded in solution.expand(root, _pageWidth)) {
        _queue.add(expanded);
      }
    }

    // If we didn't find a solution without overflow, pick the least bad one.
    return best;
  }
}
