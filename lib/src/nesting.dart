// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting;

import 'chunk.dart';
import 'line_splitter.dart';

/// Keeps track of indentation caused by wrapped nested expressions within a
/// line.
class Nester {
  /// The current level of statement/definition indentation.
  ///
  /// If a split changes this, that resets the nesting stack, since expression
  /// nesting is specific to the current innermost statement being formatted.
  /// Consider a long method call containing a function body which in turn
  /// contains long method call. The nested stack of the inner call is
  /// unrelated to the outer one.
  int _indent;

  /// The current nesting stack.
  NestingStack _nesting;

  Nester(this._indent, this._nesting);

  /// Updates the indentation state with [split], which should be an enabled
  /// split.
  ///
  /// Returns the number of levels of indentation the next line should have.
  int handleSplit(SplitChunk split) {
    if (!split.isInExpression) return split.indent;

    if (split.indent != _indent) {
      _nesting = new NestingStack();
      _indent = split.indent;
    }

    _nesting = _nesting.modify(split);
    if (_nesting == null) return INVALID_SPLITS;

    return _indent + _nesting.indent;
  }
}

/// Maintains a stack of nested expressions that have currently been split.
///
/// A single statement may have multiple different levels of indentation based
/// on the expression nesting level at the point where the line is broken. For
/// example:
///
///     someFunction(argument, argument,
///         innerFunction(argument,
///             innermost), argument);
///
/// This means that when splitting a line, we need to keep track of the nesting
/// level of the previous line(s) to determine how far the next line must be
/// indented.
///
/// This class is a persistent collection. Each instance is immutable and
/// methods to modify it return a new collection.
class NestingStack {
  /// The number of visible indentation levels for the current nesting.
  ///
  /// This may be less than [_depth] since split lines can skip multiple
  /// nesting depths.
  final int indent;

  final NestingStack _parent;

  /// The number of surrounding expression nesting levels.
  final int _depth;

  NestingStack() : this._(null, -1, 0);

  NestingStack._(this._parent, this._depth, this.indent);

  /// LinePrefixes implement their own value equality to ensure that two
  /// prefixes with the same nesting stack are considered equal even if the
  /// nesting occurred from different splits.
  ///
  /// For example, consider these two prefixes with `^` marking where splits
  /// have been applied:
  ///
  ///     fn( first, second, ...
  ///        ^
  ///     fn( first, second, ...
  ///               ^
  ///
  /// These are equivalent from the view of the suffix because they have the
  /// same nesting stack, even though the nesting came from different tokens.
  /// This lets us reuse memoized suffixes more frequently when solving.
  bool operator ==(other) {
    if (other is! NestingStack) return false;

    var self = this;
    while (self != null) {
      if (self._depth != other._depth) return false;
      self = self._parent;
      other = other._parent;

      // They should be the same length.
      if ((self == null) != (other == null)) return false;
    }

    return true;
  }

  int get hashCode {
    // TODO(rnystrom): Is it worth iterating throught the stack?
    return indent.hashCode ^ _depth.hashCode;
  }

  /// Modifies the nesting stack by taking into account [split].
  ///
  /// Returns a new nesting stack (which may the same as `this` if no change
  /// was needed). Returns `null` if the split is not allowed for the current
  /// indentation stack. This can happen if a level of nesting is skipped on a
  /// previous line but then needed on a later line. For example:
  ///
  ///     // 40 columns                           |
  ///     callSomeMethod(innerFunction(argument,
  ///         argument, argument), argument, ...
  ///
  /// Here, the second line is indented one level even though it is two levels
  /// of nesting deep (the `(` after `callSomeMethod` and `innerFunction`).
  /// When trying to indent the third line, we are not only one level in, but
  /// there is no level of indentation on the stack that corresponds to that.
  /// When that happens, we just consider this an invalid solution and discard
  /// it.
  NestingStack modify(SplitChunk split) {
    if (!split.isInExpression) return this;

    if (split.nesting == _depth) return this;

    if (split.nesting > _depth) {
      // This expression is deeper than the last split, so add it to the
      // stack.
      return new NestingStack._(this, split.nesting, indent + INDENTS_PER_NEST);
    }

    // Pop items off the stack until we find the level we are now at.
    var stack = this;
    while (stack != null) {
      if (stack._depth == split.nesting) return stack;
      stack = stack._parent;
    }

    // If we got here, the level wasn't found. That means there is no correct
    // stack level to pop to, since the stack skips past our indentation level.
    return null;
  }

  String toString() {
    var nesting = this;
    var levels = [];
    while (nesting != null) {
      levels.add("${nesting._depth}:${nesting.indent}");
      nesting = nesting._parent;
    }

    return levels.join(" ");
  }
}
