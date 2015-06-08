// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting_writer;

/// Keeps track of block indentation and expression nesting while the source
/// code is being visited and the chunks are being written.
class NestingWriter {
  /// The expression nesting level within each block level.
  ///
  /// This is tracked as a stack of numbers. Each element in the stack
  /// represents a level of block indentation. The number of the element is the
  /// number of expression nesting levels in that block.
  ///
  /// It's stored as a stack because expressions may contain blocks which in
  /// turn contain other expressions. The nesting level of the inner
  /// expressions are unrelated to the surrounding ones. For example:
  ///
  ///     outer(invocation(() {
  ///       inner(lambda());
  ///     }));
  ///
  /// When writing `inner(lambda())`, we need to track its nesting level. At
  /// the same time, when the lambda is done, we need to return to the nesting
  /// level of `outer(invocation(...`.
  ///
  /// Has an implicit entry for top-most expression nesting outside of any
  /// block for things like wrapped directives.
  final List<int> _stack = [0];

  // TODO(rnystrom): Unify with _stack?
  /// The initial absolute indentation level of each of the currently open
  /// bodies.
  // TODO(bob): Remove when functions use block nesting.
  final _bodies = [0];

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
  int _pendingNesting;

  /// The current number of open bodies.
  int get bodyDepth => _bodies.length - 1;

  /// The current number of levels of indentation within the current body.
  int get indentation => _absoluteIndent - _bodies.last;

  /// The nesting depth of the current inner-most block.
  int get nesting => _stack.last;

  /// The nesting depth of the current inner-most block, including any pending
  /// nesting.
  int get currentNesting =>
      _pendingNesting != null ? _pendingNesting : _stack.last;

  /// The total current number of levels of block indentation.
  int get _absoluteIndent => _stack.length - 1;

  /// Begins a new body.
  void startBody() {
    _bodies.add(_absoluteIndent);
  }

  /// Ends the innermost body.
  void endBody() {
    _bodies.removeLast();
  }

  /// Increases indentation of the next line in the current body by [levels].
  void indent([int levels = 1]) {
    assert(_pendingNesting == null);

    while (levels-- > 0) _stack.add(0);
  }

  /// Decreases indentation of the next line in the current body by [levels].
  void unindent([int levels = 1]) {
    assert(_pendingNesting == null);

    while (levels-- > 0) _stack.removeLast();
  }

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nest() {
    if (_pendingNesting != null) {
      _pendingNesting++;
    } else {
      _pendingNesting = nesting + 1;
    }
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    // By the time the nesting is done, it should have emitted some text and
    // not be pending anymore.
    assert(_pendingNesting == null);

    _setNesting(nesting - 1);
  }

  /// Applies any pending nesting now that we are ready for it to take effect.
  void commitNesting() {
    if (_pendingNesting == null) return;

    _setNesting(_pendingNesting);
    _pendingNesting = null;
  }

  /// Sets the nesting level of the innermost block to [value].
  void _setNesting(int value) {
    _stack[_stack.length - 1] = value;
  }
}
