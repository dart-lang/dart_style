// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../piece/piece.dart';
import 'solution.dart';
import 'solver.dart';

/// Maintains a cache of [Piece] subtrees that have been previously solved.
///
/// If a given [Piece] has newlines before and after it, then (in most cases,
/// assuming there are no other constraints) the way it is formatted only
/// depends on its leading indentation. In that case, we can format that piece
/// using a separate Solver and insert the results in any Solution that has
/// that piece at that leading indentation.
///
/// This cache stores those previously formatted subtree pieces so that
/// [CodeWriter] can reuse them across [Solution]s.
///
/// Note that this cache is shared across all Solvers and Solutions for an
/// entire format operation. Different Solvers and Solutions may end up reaching
/// the same child Piece and wanting to format it separately with the same
/// indentation. When that happens, sharing this cache allows us to reuse that
/// cached subtree Solution.
class SolutionCache {
  final _cache = <_Key, Solution>{};

  /// Returns a previously cached solution for formatting [root] with leading
  /// [indent] or produces a new solution, caches it, and returns it.
  ///
  /// If [root] is already bound to a state in the surrounding piece tree's
  /// [Solution], then [stateIfBound] is that state. Otherwise, it is treated
  /// as unbound and the cache will find a state for [root] as well as its
  /// children.
  Solution find(int pageWidth, Piece root, int indent, State? stateIfBound) {
    // See if we've already formatted this piece at this indentation. If not,
    // format it and store the result.
    return _cache.putIfAbsent(
        (root, indent: indent),
        () => Solver(this, pageWidth: pageWidth, leadingIndent: indent)
            .format(root, stateIfBound));
  }
}

/// The key used to uniquely identify a previously formatted Piece.
///
/// Each subtree solution depends only on the Piece and the amount of leading
/// indentation in the context where it appears (which may vary based on how
/// surrounding pieces end up splitting).
///
/// In particular, note that if surrounding pieces split in *different* ways
/// that still end up producing the same overall leading indentation, we are
/// able to reuse a previously cached Solution for some Piece.
typedef _Key = (Piece, {int indent});
