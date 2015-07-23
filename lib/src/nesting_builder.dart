// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting_builder;

import 'nesting_level.dart';
import 'whitespace.dart';

/// Keeps track of expression nesting while the source code is being visited
/// and the chunks are being built.
class NestingBuilder {
  /// The expression nesting levels and block indentation levels.
  ///
  /// This is tracked as a stack of [_IndentLevel]s. Each element in the stack
  /// represents a level of block indentation. It's stored as a stack because
  /// expressions may contain blocks which in turn contain other expressions.
  /// The nesting level of the inner expressions are unrelated to the
  /// surrounding ones. For example:
  ///
  ///     outer(invocation(() {
  ///       inner(lambda());
  ///     }));
  ///
  /// When writing `inner(lambda())`, we need to track its nesting level. At
  /// the same time, when the lambda is done, we need to return to the nesting
  /// level of `outer(invocation(...`.
  // TODO(rnystrom): I think this is no longer true now that blocks are handled
  // as separate nested chunks. Once cascades use expression nesting, we may
  // be able to just store a single nesting depth in NestingBuilder.
  ///
  /// Has an implicit entry for top-most expression nesting outside of any
  /// block for things like wrapped directives.
  final List<_IndentLevel> _stack = [new _IndentLevel(0)];

  /// When not `null`, the nesting level of the current innermost block after
  /// the next token is written.
  ///
  /// When the nesting level is increased, we don't want it to take effect until
  /// after at least one token has been written. That ensures that comments
  /// appearing before the first token are correctly indented. For example, a
  /// binary operator expression increases the nesting before the first operand
  /// to ensure any splits within the left operand are handled correctly. If we
  /// changed the nesting level immediately, then code like:
  ///
  ///     {
  ///       // comment
  ///       foo + bar;
  ///     }
  ///
  /// would incorrectly get indented because the line comment adds a split which
  /// would take the nesting level of the binary operator into account even
  /// though we haven't written any of its tokens yet.
  NestingLevel _pendingNesting;

  /// The current number of characters of block indentation.
  int get indentation => _stack.last.indent;

  /// The nesting depth of the current inner-most block.
  NestingLevel get nesting => _stack.last.nesting;

  /// The nesting depth of the current inner-most block, including any pending
  /// nesting.
  NestingLevel get currentNesting =>
      _pendingNesting != null ? _pendingNesting : _stack.last.nesting;

  /// The top "nesting level" that represents no expression nesting for the
  /// current block.
  NestingLevel get blockNesting {
    // Walk the nesting levels until we bottom out.
    var result = nesting;
    while (result.parent != null) {
      result = result.parent;
    }
    return result;
  }

  /// Creates a new indentation level [spaces] deeper than the current one.
  ///
  /// If omitted, [spaces] defaults to [Indent.block].
  void indent([int spaces]) {
    if (spaces == null) spaces = Indent.block;

    assert(_pendingNesting == null);

    _stack.add(new _IndentLevel(_stack.last.indent + spaces));
  }

  /// Discards the most recent indentation level.
  void unindent() {
    assert(_pendingNesting == null);
    _stack.removeLast();
  }

  /// Begins a new expression nesting level [indent] deeper than the current
  /// one if it splits.
  ///
  /// If [indent] is omitted, defaults to [Indent.expression].
  void nest([int indent]) {
    if (indent == null) indent = Indent.expression;

    if (_pendingNesting != null) {
      _pendingNesting = _pendingNesting.nest(indent);
    } else {
      _pendingNesting = nesting.nest(indent);
    }
  }

  /// Discards the most recent level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    // By the time the nesting is done, it should have emitted some text and
    // not be pending anymore.
    assert(_pendingNesting == null);

    _setNesting(nesting.parent);
  }

  /// Applies any pending nesting now that we are ready for it to take effect.
  void commitNesting() {
    if (_pendingNesting == null) return;

    _setNesting(_pendingNesting);
    _pendingNesting = null;
  }

  /// Sets the nesting level of the innermost block to [level].
  void _setNesting(NestingLevel level) {
    _stack.last.nesting = level;
  }
}

/// A level of block nesting.
///
/// This represents indentation changes that typically occur at statement or
/// block boundaries.
class _IndentLevel {
  /// The number of spaces of indentation at this level.
  final int indent;

  /// The current expression nesting in this indentation level.
  NestingLevel nesting = new NestingLevel();

  _IndentLevel(this.indent);
}
