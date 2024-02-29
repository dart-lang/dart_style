// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:collection/collection.dart';

import '../debug.dart' as debug;
import '../piece/piece.dart';
import 'solution.dart';
import 'solution_cache.dart';

/// Selects states for each piece in a tree of pieces to find the best set of
/// line splits that minimizes overflow characters and line splitting costs.
///
/// This problem is combinatorial over the number of pieces and each of their
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
///     newlines. See [Solution._nextPieceToExpand] for more details.
///
/// -   If a subtree Piece is sufficiently isolated from surrounding content
///     (usually this means it is on its own line), then we hoist that entire
///     subtree out, format it with a separate Solver, and then insert the
///     result into the Solution. We also memoize the result of doing this and
///     use it across different Solutions. This enables us to both divide and
///     conquer the Piece tree and solve portions separately, while also
///     reusing work across different solutions.
class Solver {
  final SolutionCache _cache;

  final int _pageWidth;
  final int _leadingIndent;

  final PriorityQueue<Solution> _queue = PriorityQueue();

  Solver(this._cache, {required int pageWidth, int leadingIndent = 0})
      : _pageWidth = pageWidth,
        _leadingIndent = leadingIndent;

  /// Finds the best set of line splits for [root] piece and returns the
  /// resulting formatted code.
  ///
  /// If [rootState] is given, then [root] is bound to that state.
  Solution format(Piece root, [State? rootState]) {
    if (debug.traceSolver) {
      var unsolved = <Piece>[];
      void traverse(Piece piece) {
        if (piece.states.length > 1) unsolved.add(piece);

        piece.forEachChild(traverse);
      }

      traverse(root);

      var label = [
        'Solving $root',
        if (rootState != null) 'at state $rootState',
        if (unsolved.isNotEmpty) 'for ${unsolved.join(', ')}',
      ].join(' ');

      debug.log(debug.bold('$label:'));
      debug.indent();
      debug.log(debug.pieceTree(root));
    }

    var solution = Solution(_cache, root,
        pageWidth: _pageWidth,
        leadingIndent: _leadingIndent,
        rootState: rootState);

    _queue.add(solution);

    // The lowest cost solution found so far that does overflow.
    var best = solution;

    var tries = 0;

    // TODO(perf): Consider bailing out after a certain maximum number of tries,
    // so that it outputs suboptimal formatting instead of hanging entirely.
    while (_queue.isNotEmpty) {
      var solution = _queue.removeFirst();
      tries++;

      if (debug.traceSolver) {
        debug.log(debug.bold('Try #$tries $solution'));
        debug.log(solution.text);
        debug.log('');
      }

      if (solution.isValid) {
        // Since we process the solutions from lowest cost up, as soon as we
        // find a valid one that fits, it's the best.
        if (solution.overflow == 0) {
          best = solution;
          break;
        }

        // If not, keep track of the least-bad one we've found so far.
        if (!best.isValid || solution.overflow < best.overflow) {
          best = solution;
        }
      }

      // Otherwise, try to expand the solution to explore different splitting
      // options.
      for (var expanded in solution.expand(_cache, root,
          pageWidth: _pageWidth, leadingIndent: _leadingIndent)) {
        _queue.add(expanded);
      }
    }

    // If we didn't find a solution without overflow, pick the least bad one.
    if (debug.traceSolver) {
      debug.unindent();
      debug.log(debug.bold('Solved $root to $best:'));
      debug.log(best.text);
      debug.log('');
    }

    return best;
  }
}
