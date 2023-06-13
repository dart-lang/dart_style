// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../chunk.dart';
import '../constants.dart';
import 'rule.dart';

/// Rule for splitting a conditional expression.
class ConditionalRule extends Rule {
  late final Chunk _questionChunk;
  late final Chunk _colonChunk;

  void bindQuestion(Chunk chunk) {
    _questionChunk = chunk;
  }

  void bindColon(Chunk chunk) {
    _colonChunk = chunk;
  }

  @override
  int chunkIndent(int value, Chunk chunk) {
    // TODO: Hack.
    // The conditional expression is nested +6 so that the operands are past
    // the "?" and ":". But for the chunks that use this rule itself, the ":"
    // and "?" ones, shift them back so that they stick out on the left.
    return -Indent.block;
  }

  @override
  String toString() => 'Cond${super.toString()}';
}
