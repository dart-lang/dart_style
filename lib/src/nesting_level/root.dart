// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'nesting_level.dart';

/// The top level of expression nesting.
class RootNestingLevel extends NestingLevel {
  int get totalUsedIndent => 0;

  RootNestingLevel() : super.protected(null);

  void clearTotalUsedIndent() {}
  void refreshTotalUsedIndent(Set<NestingLevel> usedNesting) {}

  String toString() => "0";
}
