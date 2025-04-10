// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

/// Tracks the contents of a nested tree of argument lists and collection
/// literals.
///
/// In general, the formatter tries to pack as much as it can on a single line
/// until it hits the page width. However, with deeply nested call trees (which
/// are pervasive in Flutter UI code), the expression nesting can get deep even
/// in a short piece of code.
///
/// It can be much easier to track the nesting structure and identify siblings
/// in the expression tree if it's forced to split more eagerly. Compare:
///
///     Apple(banana: [Cherry(date: Eggplant(1, 2))], fig: Grape(4))
///
///     Apple(
///       banana: [
///         Cherry(date: Eggplant(1, 2)),
///       ],
///       fig: Grape(4),
///     )
///
/// This class records the necessary state to determine if a given collection
/// literal or argument list is complex enough that it should be eagerly split.
///
/// It considers an operation A to contain another B if B occurs anywhere
/// transitively inside the elements or argument list of A, regardless of any
/// other AST nodes that may intercede. If we only looked at the immediate
/// expressions in the collection or argument list to count nested calls and
/// collections, then wrapping one of those expressions in, say, parentheses,
/// could cause a nested operation to *not* be counted.
///
/// That would violate a reasonable principle that *adding* code to a call or
/// collection should never cause it to go from splitting to not splitting. If a
/// collection or call is complex enough to warrant splitting it eagerly, then
/// adding more code in there should always lead to it still splitting.
/// Tracking the contents transitively ensures that.
///
/// The heuristics for which collections and argument lists split are fairly
/// simple and conservative and are documented below.
class ExpressionContents {
  /// The stack of calls and collections whose contents we are tracking and
  /// that haven't completed yet.
  final List<_Contents> _stack = [_Contents(_Type.otherCall)];

  /// Begins tracking an argument list.
  void beginCall(List<AstNode> arguments) {
    var type = _Type.otherCall;

    // Count the non-trivial named arguments in this call.
    var namedArguments = 0;
    for (var argument in arguments) {
      if (argument is NamedExpression) {
        type = _Type.callWithNamedArgument;
        if (!_isTrivial(argument.expression)) namedArguments++;
      }
    }

    _stack.add(_Contents(type, namedArguments: namedArguments));
  }

  /// Ends the most recently begun call and returns `true` if its argument list
  /// should eagerly split.
  bool endCall(List<Expression> arguments) {
    var contents = _end();

    // If there are "too many" named arguments in this call and the calls it
    // contains, then split it.
    //
    // The basic idea is that when scanning a line of code, it's hard to tell
    // which calls own which named arguments if there are named arguments at
    // multiple levels in the call tree. Splitting makes that clearer. At the
    // same time, it's annoying it the formatter is too aggressive about
    // splitting an expression that feels simple enough to the reader to fit on
    // one line. (Especially because if the formatter does eagerly split it,
    // there's nothing they can do to *prevent* that.)
    //
    // The heuristic here tries to strike a "Goldilocks" balance between not
    // splitting too aggressively or too conservatively. The rule is that the
    // entire call tree must contain at least three named arguments, at least
    // one must be in the outermost call being split, and at least one must
    // *not* be in the outermost call.
    //
    // It would be simpler to split any call that has named arguments at
    // different nesting levels, but that's a little too aggressive and forces
    // common code like this to split:
    //
    //       Text('Item 1', style: TextStyle(color: Colors.white));
    return contents.totalNamedArguments > 2 &&
        contents.namedArguments > 0 &&
        contents.nestedNamedArguments > 0;
  }

  /// Begin tracking a collection literal and its contents.
  void beginCollection({bool isNamed = false}) {
    _stack.last.collections++;
    _stack.add(_Contents(isNamed ? _Type.namedCollection : _Type.collection));
  }

  /// Ends the most recently begun collection literal and returns whether it
  /// should eagerly split.
  bool endCollection(List<AstNode> elements) {
    var contents = _end();

    // Split any collection that contains another non-empty collection.
    if (contents.collections > 0) return true;

    // If the collection is itself a named argument in a surrounding call that
    // may be be forced to eagerly split, then split the collection too. In
    // that case, the collection is sort of like a vararg argument to the call.
    // Prefers:
    //
    //     TabBar(
    //       tabs: <Widget>[
    //         Tab(text: 'Tab 1'),
    //         Tab(text: 'Tab 2'),
    //       ],
    //     );
    //
    // Over:
    //
    //     TabBar(
    //       tabs: <Widget>[Tab(text: 'Tab 1'), Tab(text: 'Tab 2')],
    //     );
    //
    // Splitting a collection is also helpful, because it shows each element
    // in parallel with each on its own line. But that's only true when there
    // are multiple elements, so we don't eagerly split collections with just a
    // single element.
    return elements.length > 1 &&
        contents.type == _Type.namedCollection &&
        contents.totalNamedArguments > 0;
  }

  /// Ends the most recently begun operation and returns its contents.
  _Contents _end() {
    var contents = _stack.removeLast();

    // Transitively include this operation's contents in the surrounding one.
    var parent = _stack.last;
    parent.collections += contents.collections;
    parent.nestedNamedArguments +=
        contents.namedArguments + contents.nestedNamedArguments;

    return contents;
  }

  /// Whether [expression] is "trivial".
  ///
  /// When deciding whether an argument list should be eagerly split, or should
  /// force surrounding argument lists to eagerly split, we ignore any named
  /// arguments whose expression is "trivial". This allows a little more code
  /// to be packed onto a single line when the inner call is creating a simple
  /// data structure with literal values, like:
  ///
  ///     MediaQueryData(padding: EdgeInsets.only(left: 40));
  ///
  /// Here, if we didn't treat `40` as a trivial expression and ignore it, then
  /// the call to `MediaQueryData(...)` would be forced to split.
  bool _isTrivial(Expression expression) {
    return switch (expression) {
      NullLiteral() => true,
      BooleanLiteral() => true,
      IntegerLiteral() => true,
      DoubleLiteral() => true,
      PrefixExpression(operator: Token(type: TokenType.MINUS), :var operand)
          when _isTrivial(operand) =>
        true,
      _ => false,
    };
  }
}

/// The number of function calls and collection literals occurring transitively
/// inside some other operation.
class _Contents {
  final _Type type;

  /// The number of non-empty list, set, and map literals transitively inside
  /// this operation.
  int collections = 0;

  /// The number of non-trivial named arguments in this call's own argument
  /// list.
  int namedArguments = 0;

  /// The number of non-trivial named arguments transitively inside this
  /// operation, but not including the call's own named arguments.
  int nestedNamedArguments = 0;

  _Contents(this.type, {this.namedArguments = 0});

  /// The total number of non-trivial named arguments in this operation's own
  /// argument list and all of transitive contents.
  int get totalNamedArguments => namedArguments + nestedNamedArguments;
}

enum _Type {
  /// A non-empty list, map, or set literal.
  collection,

  /// A non-empty list, map, or set literal that is the immediate expression in
  /// a named argument in a surrounding argument list.
  namedCollection,

  /// An argument list with at least one named argument and which may be subject
  /// to eager splitting.
  callWithNamedArgument,

  /// An argument list with no named arguments that isn't subject to eager
  /// splitting.
  otherCall,
}
