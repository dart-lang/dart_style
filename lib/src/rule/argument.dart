// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../chunk.dart';
import '../constants.dart';
import 'rule.dart';

/// Rule for an argument list that contains some block-like argument, as in:
///
/// ```
/// test('description', () {
///   ...
/// });
/// ```
abstract class ArgumentListRule extends Rule with TrackInnerRulesMixin {
  late final Chunk _rightParenthesisChunk;

  void bindRightParenthesis(Chunk chunk) {
    _rightParenthesisChunk = chunk;
  }

  @override
  int chunkIndent(int value, Chunk chunk) {
    // Don't indent the closing ")"
    if (chunk == _rightParenthesisChunk) return 0;

    // Indent other arguments.
    return Indent.block;
  }

  @override
  String toString() => 'Args${super.toString()}';
}

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
class CollectionArgumentListRule extends ArgumentListRule {
  late final Chunk _blockChunk;

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
  int chunkIndent(int value, Chunk chunk) {
    // Only indent the body of the block argument if the arguments split.
    if (chunk == _blockChunk) {
      return value == 3 ? Indent.block : 0;
    }

    return super.chunkIndent(value, chunk);
  }
}

/// Rule for an argument list that contains a block-like function argument, as
/// in:
///
/// ```
/// function(argument, () {
///   ;
/// });
/// ```
///
/// Since the function body always splits, the rule only has two values:
///
/// 0. Split the function body, but not the arguments.
///
///     ```
///     function(argument, () {
///       ;
///     });
///     ```
///
/// 1. Split the arguments and the function body.
///
///     ```
///     function(
///       argument,
///       () {
///         ;
///       }
///     );
///     ```
class FunctionArgumentListRule extends ArgumentListRule {}

// TODO: Remove.
/// Base class for a rule that handles argument or parameter lists.
abstract class ArgumentRule extends Rule with TrackInnerRulesMixin {
  /// The chunks prior to each positional argument.
  final List<Chunk?> _arguments = [];

  /// Remembers [chunk] as containing the split that occurs right before an
  /// argument in the list.
  void beforeArgument(Chunk? chunk) {
    _arguments.add(chunk);
  }
}
