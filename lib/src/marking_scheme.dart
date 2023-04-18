// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A mixin for marking classes.
mixin MarkingScheme {
  int _markingFlag = 0;

  bool mark() {
    if (_markingFlag != 0) return false;
    _markingFlag = 1;
    return true;
  }

  bool isMarked() => _markingFlag != 0;

  void unmark() {
    _markingFlag = 0;
  }
}
