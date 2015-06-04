// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.nesting;

/// The number of indentation levels in a single level of expression nesting.
const _indentsPerNest = 2;

/// Manages the linked chain of nesting where a point in code may appear.
///
/// This is used to define the unique identity of a [LinePrefix].
///
/// Consider the following code:
///
///     function(
///         argument,
///         wrapper(() {
///           alpha(beta(gamma("here"))));
///         }),
///         argument);
///
/// We are sitting at "here". What is the state we need to store in order to
/// be able to determine where a newline starts if we split before that string?
/// This class contains that state.
///
/// It is a linked list of nesting levels from the innermost out to the
/// top-level code. Each node can represent a level of expression nesting
/// (this class), or a body ([_BodyNesting]). In this example, that's:
///
/// * The expression level for the argument list for `gamma()`.
/// * The expression level for the argument list for `beta()`.
/// * The expression level for the argument list for `alpha()`.
/// * The body of the anonymous function.
/// * The expression level for the argument list for `wrapper()`.
/// * The expression level for the argument list for `function()`.
/// * The top-level body.
///
/// In many cases, some expression levels will be omitted from the stack. This
/// happens when a split doesn't occur at that nesting level so it doesn't get
/// an indentation column bound to that level. (For example, in the above code,
/// there are no splits in `alpha(beta(gamma("here"))))` so those expression
/// depths are not represented.)
///
/// The entire stack is a persistent collection. Each instance is immutable and
/// methods to modify it return a new collection. The stack is stored as a
/// linked list from inner to outer nodes so that a "new" stack can reuse almost
/// all of an existing one.
///
class ExpressionNesting {
  /// The body containing this expression nesting.
  final _BodyNesting _body;

  final ExpressionNesting _parent;

  /// The number of visible indentation levels for the current nesting.
  ///
  /// Takes into account both expression and surrounding body nesting.
  ///
  /// This may be less than [_depth] since split lines can skip multiple
  /// nesting depths.
  int get indent => _body.indent + _indent;
  final int _indent;

  /// The number of surrounding expression nesting levels.
  int get depth => _depth;
  final int _depth;

  ExpressionNesting() : this._(new _BodyNesting._(null, 0, 0), null, 0, 0);

  ExpressionNesting._(this._body, this._parent, this._depth, this._indent);

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
    if (other is! ExpressionNesting) return false;

    var thisExpression = this;
    var otherExpression = other;
    while (thisExpression != null) {
      if (thisExpression._indent != otherExpression._indent) return false;
      if (thisExpression._depth != otherExpression._depth) return false;
      thisExpression = thisExpression._parent;
      otherExpression = otherExpression._parent;

      // They should be the same length.
      if ((thisExpression == null) != (otherExpression == null)) return false;
    }

    return _body == other._body;
  }

  int get hashCode {
    // TODO(rnystrom): Is it worth iterating through the stack?
    return _indent.hashCode ^ _depth.hashCode;
  }

  /// Updates the nesting to match expression [nestingDepth] at [bodyDepth]
  /// with [newIndent].
  ///
  /// Pushes or pops bodies as needed to match [bodyDepth]. If a new body is
  /// added, its initial indentation will be [newIndent]. Then, updates the
  /// innermost expression nesting to match [nestingDepth].
  List<ExpressionNesting> update(int bodyDepth, int newIndent, int nestingDepth) {
    // Update the body stack to get to the chunk's body.
    var nesting = this;

    // If we have exited any bodies, return to the previous indentation depth.
    while (bodyDepth < nesting._body.depth) {
      nesting = _body._expression;
    }

    // If we have entered a new body, keep track of it.
    if (bodyDepth > _body.depth) {
      // Should never jump into more than one body in a single chunk. The rules
      // for how inner bodies force outer splits should prevent this from
      // occurring.
      assert(bodyDepth == _body.depth + 1);

      var newBody = new _BodyNesting._(nesting, bodyDepth, newIndent);
      nesting = new ExpressionNesting._(newBody, null, 0, 0);
    }

    return nesting._updateExpression(nestingDepth);
  }

  /// Takes this nesting stack and produces all of the new nesting stacks that
  /// are possible when followed by the nesting level of [split].
  ///
  /// This may produce multiple solutions because a non-incremental jump in
  /// nesting depth can be sliced up multiple ways. Let's say the prefix is:
  ///
  ///     first(second(third(...
  ///
  /// The current nesting stack is empty (since we're on the first line). How
  /// do we modify it by taking into account the split after `third(`? The
  /// simple answer is to just increase the indentation by one level:
  ///
  ///     first(second(third(
  ///         argumentToThird)));
  ///
  /// This is correct in most cases, but not all. Consider:
  ///
  ///     first(second(third(
  ///         argumentToThird),
  ///     argumentToSecond));
  ///
  /// Oops! There's no place for `argumentToSecond` to go. To handle that, the
  /// second line needs to be indented one more level to make room for the later
  /// line:
  ///
  ///     first(second(third(
  ///             argumentToThird),
  ///         argumentToSecond));
  ///
  /// It's even possible we may need to do:
  ///
  ///     first(second(third(
  ///                 argumentToThird),
  ///             argumentToSecond),
  ///         argumentToFirst);
  ///
  /// To accommodate those, this returns the list of all possible ways the
  /// nesting stack can be modified.
  List<ExpressionNesting> _updateExpression(int nestingDepth) {
    if (nestingDepth == _depth) return [this];

    // If the new split is less nested than we currently are, pop and discard
    // the previous nesting levels.
    if (nestingDepth < _depth) {
      // Pop items off the stack until we find the level we are now at.
      var stack = this;
      while (stack != null) {
        if (stack._depth == nestingDepth) return [stack];
        stack = stack._parent;
      }

      // If we got here, the level wasn't found. That means there is no correct
      // stack level to pop to, since the stack skips past our indentation
      // level.
      return [];
    }

    // Going deeper, so try every indentating for every subset of expression
    // nesting levels between the old and new one.
    return _intermediateDepths(_depth, nestingDepth).map((depths) {
      var result = this;

      for (var depth in depths) {
        result = new ExpressionNesting._(
            _body, result, depth, result._indent + _indentsPerNest);
      }

      return new ExpressionNesting._(
          _body, result, nestingDepth, result._indent + _indentsPerNest);
    }).toList();
  }

  /// Given [min] and [max], generates all of the subsets of numbers in that
  /// range (exclusive), including the empty set.
  ///
  /// This is used to determine what sets of intermediate nesting levels to
  /// consider when jumping from a shallow nesting level to a much deeper one.
  /// Subsets are generated in order of increasing length. For example, `(2, 6)`
  /// yields:
  ///
  ///     []
  ///     [3] [4] [5]
  ///     [3, 4] [3, 5] [4, 5]
  ///     [3, 4, 5]
  ///
  /// This ensures the splitter prefers solutions that use the least
  /// indentation.
  List<List<int>> _intermediateDepths(int min, int max) {
    assert(min < max);

    var subsets = [[]];

    var lastLengthStart = 0;
    var lastLengthEnd = subsets.length;

    // Generate subsets in order of increasing length.
    for (var length = 1; length <= max - min + 1; length++) {
      // Start with each subset containing one fewer element.
      for (var i = lastLengthStart; i < lastLengthEnd; i++) {
        var previousSubset = subsets[i];

        var start = previousSubset.isNotEmpty ? previousSubset.last + 1 : min + 1;

        // Then for each value in the remainer, make a new subset that is the
        // union of the shorter subset and that value.
        for (var j = start; j < max; j++) {
          var subset = previousSubset.toList()..add(j);
          subsets.add(subset);
        }
      }

      // Move on to the next length range.
      lastLengthStart = lastLengthEnd;
      lastLengthEnd = subsets.length;
    }

    return subsets;
  }

  /// Shows each indentation level and the nesting depth associated with it.
  ///
  /// For example:
  ///
  ///     |1|3
  ///
  /// Means that the first level of indentation is associated with nesting
  /// level one, and the second level of indentation is associated with nesting
  /// level three.
  String toString() {
    var result = "";

    for (var nesting = this; nesting._depth != 0; nesting = nesting._parent) {
      result = "|${nesting._depth}$result";
    }

    // TODO(rnystrom): Include body.
    return result;
  }
}

/// Nesting stack node representing a "body". This includes top-level code,
/// function literals, and collection literals.
class _BodyNesting {
  /// The expression where this body appears, or `null` if this is the outermost
  /// body.
  final ExpressionNesting _expression;

  /// The number of visible indentation levels for the body.
  final int indent;

  /// The number of surrounding bodies.
  int get depth => _depth;
  final int _depth;

  _BodyNesting._(this._expression, this._depth, this.indent);

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
    if (other is! _BodyNesting) return false;

    if (indent != other.indent) return false;
    if (_depth != other._depth) return false;

    return _expression == other._expression;
  }

  int get hashCode {
    // TODO(rnystrom): Is it worth iterating through the stack?
    return indent.hashCode ^ _depth.hashCode;
  }
}
