// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.multisplit;

import 'chunk.dart';

/// Handles a series of [Chunks] that all either split or don't split together.
///
/// This is used for:
///
/// * Map and list literals.
/// * A series of the same binary operator.
/// * A series of chained method calls.
/// * Cascades.
/// * The beginning and ending of curly brace bodies.
///
/// In all of these, either the entire construct will be a single line, or it
/// will be fully split into multiple lines, with no intermediate states
/// allowed.
///
/// There is still the question of how a multisplit handles an explicit newline
/// (usually from a function literal subexpression) contained within the
/// multisplit. There are two variations: separable and inseparable. Most are
/// the latter.
///
/// An inseparable multisplit treats a hard newline as forcing the entire
/// multisplit to split, like so:
///
///     [
///       () {
///         // This forces the surrounding list to be split.
///       }
///     ]
///
/// A separable one breaks the multisplit into two independent multisplits, each
/// of which may or may not be split based on its own range. For example:
///
///     compiler
///         .somethingLong()
///         .somethingLong()
///         .somethingLong((_) {
///       // The calls above this split because they are long.
///     }).a().b();
///     The trailing calls are short enough to not split.
class Multisplit {
  /// The index of the first chunk contained by the multisplit.
  ///
  /// This is used to determine which chunk range needs to be scanned to look
  /// for hard newlines to see if the multisplit gets forced.
  final int startChunk;

  /// The [SplitParam] that controls all of the split chunks.
  SplitParam get param => _param;
  SplitParam _param = new SplitParam();

  /// `true` if a hard newline has forced this multisplit to be split.
  bool _isSplit = false;

  final bool _separable;

  Multisplit(this.startChunk, {bool separable})
      : _separable = separable != null ? separable : false;

  /// Handles a hard split occurring in the middle of this multisplit.
  ///
  /// If the multisplit is separable, this creates a new param so the previous
  /// split chunks can vary independently of later ones. Otherwise, it just
  /// marks this multisplit as being split.
  ///
  /// Returns a [SplitParam] for existing splits that should be hardened if this
  /// splits a non-separable multisplit for the first time. Otherwise, returns
  /// `null`.
  SplitParam harden() {
    if (_isSplit) return null;

    _isSplit = true;

    if (_separable) {
      _param = new SplitParam(param.cost);

      // Previous splits may still remain unsplit.
      return null;
    } else {
      // Any other splits created from this multisplit should be hardened now.
      var oldParam = _param;
      _param = null;
      return oldParam;
    }
  }
}
