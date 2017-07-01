// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'chunk.dart';

/// A marker indicating a horizontal position in the document, which may change
/// depending on where splits are placed.
///
/// This is aligned to the left-hand edge of [_chunk] plus [_extraDepth]
/// characters. It's created by [ChunkBuilder] without a specific chunk, and
/// then finalized with [finalize] before it's actually used. This lets the
/// alignment refer either to the middle of an existing chunk or to the
/// beginning of the next chunk, depending on the document's shape.
class Alignment {
  /// The chunk whose left-hand side determines the alignment.
  Chunk _chunk;

  /// The extra characters into [_chunk] to align to.
  int _extraDepth;

  /// The depth to align to, from the left-hand side of the current block.
  ///
  /// This is only valid during line splitting.
  int get depth => _chunk.depth + _extraDepth;

  /// Sets [chunk] and [extraDepth].
  ///
  /// This may only be called once per alignment.
  void finalize(Chunk chunk, [int extraDepth]) {
    assert(_chunk == null);
    _chunk = chunk;
    _extraDepth = extraDepth ?? 0;
  }
}
