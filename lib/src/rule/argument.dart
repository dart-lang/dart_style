// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../chunk.dart';
import '../constants.dart';
import 'rule.dart';

/// Rule for an argument list that contains a block-like collection argument,
/// as in:
///
/// ```
/// function(argument, [
///   element,
///   element
/// ]);
/// ```
///
/// This rule contains four values:
///
/// 0.  Don't split the arguments or the block argument contents:
///
///     ```
///     function(argument, [element, element]);
///     ```
///
/// 1. Split the block argument contents, but not the arguments.
///
///     ```
///     function(argument, [
///       element,
///       element
///     ]);
///     ```
///
/// 2. Split the arguments but not the block argument contents.
///
///     ```
///     function(
///       argument,
///       [element, element]
///     );
///     ```
///
/// 3. Split the arguments and the block argument contents.
///
///     ```
///     function(
///       argument,
///       [
///         element,
///         element
///       ]
///     );
///     ```
class ArgumentListRule extends TrackInnerRule {
  /// The chunk where the splittable block argument begins.
  ///
  /// If the block argument is a for a function (which always splits), this
  /// will be `null`.
  Chunk? _blockChunk;

  void bindBlock(Chunk chunk) {
    _blockChunk = chunk;
  }

  @override
  int get numValues => 4;

  @override
  bool isSplitAtValue(int value, Chunk chunk) {
    switch (value) {
      case 0:
        return false;
      case 1:
        return chunk == _blockChunk;
      case 2:
        return chunk != _blockChunk;
      default:
        return true;
    }
  }

  @override
  int nestingIndent(int value, {required bool isUsed}) {
    if (!isUsed) return 0;

    return switch (value) {
      2 || 3 => Indent.block,
      _ => Indent.none,
    };
  }

  @override
  String toString() => 'Args${super.toString()}';
}
