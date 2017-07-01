// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'nesting_level.dart';

/// An indented level of expression nesting.
///
/// This nesting level has an [_indent], which is the number of spaces it is
/// indented relative to the outer expression. It's almost always
/// [Indent.expression], but cascades are special magic snowflakes and use
/// [Indent.cascade].
class IndentedNestingLevel extends NestingLevel {
  /// The number of characters that this nesting level is indented relative to
  /// the containing level.
  ///
  /// Normally, this is [Indent.expression], but cascades use [Indent.cascade].
  final int _indent;

  /// The total number of characters of indentation from this level and all of
  /// its parents, after determining which nesting levels are actually used.
  ///
  /// This is only valid during line splitting.
  int get totalUsedIndent => _totalUsedIndent;
  int _totalUsedIndent;

  IndentedNestingLevel(NestingLevel parent, this._indent)
      : super.protected(parent);

  void clearTotalUsedIndent() {
    _totalUsedIndent = null;
    parent.clearTotalUsedIndent();
  }

  void refreshTotalUsedIndent(Set<NestingLevel> usedNesting) {
    if (_totalUsedIndent != null) return;

    parent.refreshTotalUsedIndent(usedNesting);
    _totalUsedIndent = parent.totalUsedIndent;
    if (usedNesting.contains(this)) _totalUsedIndent += _indent;
  }

  String toString() => "$parent:$_indent";
}
