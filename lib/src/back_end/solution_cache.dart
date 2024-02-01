// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../piece/piece.dart';
import 'solution.dart';
import 'solver.dart';

/// Maintains a cache of [Piece] subtrees that have been previously solved.
///
/// If a given [Piece] has newlines before and after it, then (in most cases,
/// assuming there are no other constraints), then the way it is formatted
/// really only depends on its leading indentation and state. In that case, we
/// can format that piece using a separate Solver and insert the results in any
/// Solution that has that piece at that leading indentation.
///
/// This cache stores those previously formatted subtree pieces so that
/// [CodeWriter] can reuse them across Solution[s].
class SolutionCache {
  final _cache = <_Key, Solution>{};

  /// Looks up a previously cached solution for formatting [root] with leading
  /// [indent].
  ///
  /// If found, returns the cached solution. Otherwise solves it, caches it,
  /// and returns the result.
  Solution find(int pageWidth, Piece root, State state, int indent) {
    // See if we've already formatted this piece at this indentation.
    var key = (root, state, indent: indent);
    if (_cache[key] case var solution?) return solution;

    var solver = Solver(this, pageWidth: pageWidth, leadingIndent: indent);
    return _cache[key] = solver.format(root, state);
  }
}

/// The key used to uniquely identify a previously formatted Piece.
///
/// Each subtree solution depends only on the Piece, the State it's bound to,
/// and amount of leading indentation in the context where it appears (which
/// may vary based on how surrounding pieces end up splitting).
///
/// In particular, note that if surrounding pieces split in *different* ways
/// that still end up producing the same overall leading indentation, we are
/// able to reuse a previously cached Solution for some Piece.
typedef _Key = (Piece, State, {int indent});
