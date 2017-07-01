// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

import '../alignment.dart';
import '../fast_hash.dart';
import 'aligned.dart';
import 'indented.dart';
import 'root.dart';

/// A single level of expression nesting.
///
/// When a line is split in the middle of an expression, this tracks the
/// context of where in the expression that split occurs. It ensures that the
/// [LineSplitter] obeys the expression nesting when deciding what column to
/// start lines at when split inside an expression.
///
/// Each instance of this represents a single level of expression nesting. If we
/// split at to chunks with different levels of nesting, the splitter ensures
/// they each get assigned to different columns.
abstract class NestingLevel extends FastHash {
  /// The nesting level surrounding this one, or `null` if this is represents
  /// top level code in a block.
  final NestingLevel parent;

  /// The total number of characters of indentation from this level and all of
  /// its parents, after determining which nesting levels are actually used.
  ///
  /// This is only valid during line splitting.
  int get totalUsedIndent;

  /// Whether this is nested, as opposed to being the root of the nesting tree.
  bool get isNested => parent != null;

  factory NestingLevel() = RootNestingLevel;

  @protected
  NestingLevel.protected(this.parent);

  /// Creates a new deeper level of nesting indented [spaces] more characters
  /// that the outer level.
  NestingLevel nest(int spaces) => new IndentedNestingLevel(this, spaces);

  /// Creates a new nesting level aligned with [alignment].
  NestingLevel align(Alignment alignment) =>
      new AlignedNestingLevel(this, alignment);

  /// Whether it's valid for this level to match [other], which is expected to
  /// be an adjacent level of nesting.
  ///
  /// This forbids multiple adjacent lines from having the same nesting level
  /// for different reasons, unless that reason is that one of them is aligned
  /// to a specific location.
  bool mayMatchNesting(NestingLevel other) =>
      identical(this, other) || other is AlignedNestingLevel;

  /// Clears the previously calculated total indent of this nesting level.
  void clearTotalUsedIndent();

  /// Calculates the total amount of indentation from this nesting level and
  /// all of its parents assuming only [usedNesting] levels are in use.
  void refreshTotalUsedIndent(Set<NestingLevel> usedNesting);
}
