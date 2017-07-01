// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../alignment.dart';
import 'nesting_level.dart';

/// An aligned level of expression nesting.
///
/// This nesting level is indented to align horizontally with [_alignment].
class AlignedNestingLevel extends NestingLevel {
  /// The alignment to match.
  final Alignment _alignment;

  int get totalUsedIndent => _totalUsedIndent;
  int _totalUsedIndent;

  AlignedNestingLevel(NestingLevel parent, this._alignment)
      : super.protected(parent);

  bool mayMatchNesting(NestingLevel other) => true;

  void clearTotalUsedIndent() {
    _totalUsedIndent = null;
    parent.clearTotalUsedIndent();
  }

  void refreshTotalUsedIndent(Set<NestingLevel> usedNesting) {
    if (_totalUsedIndent != null) return;

    parent.refreshTotalUsedIndent(usedNesting);

    _totalUsedIndent =
        usedNesting.contains(this) ? _alignment.depth : parent.totalUsedIndent;
  }

  String toString() => "$parent:aligned";
}
