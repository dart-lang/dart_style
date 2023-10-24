// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a bracket-delimited, comma-separated series of items.
///
/// Used for argument lists, collection literals, parameter lists, etc. This
/// class handles adding and removing the trailing comma depending on whether
/// the list is split or not.
///
/// Usually constructed using [createDelimited()] or a [DelimitedListBuilder].
class ListPiece extends Piece {
  /// The called expression and the subsequent "(".
  final Piece _before;

  /// The list of piece pairs, one for each argument and one for the comma
  /// after the argument.
  ///
  /// We create a comma piece after every argument, even the last. We do this
  /// even if the original source code didn't have a trailing comma. When the
  /// piece is formatted, if it fits on one line, the final comma piece is
  /// discarded. Otherwise it is included.
  final List<ListElement> _arguments;

  /// The arguments that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElement> _blanksAfter;

  /// The ")" after the arguments.
  final Piece _after;

  /// Whether this list should have a trailing comma if it splits.
  ///
  /// This is true for most lists but false for type parameters, type arguments,
  /// and switch values.
  final bool _trailingComma;

  /// The state when the list is split.
  ///
  /// We use this instead of [State.split] because the cost is higher for some
  /// kinds of lists.
  // TODO(rnystrom): Having to use a different state for this is a little
  // cumbersome. Maybe it would be better to most costs out of [State] and
  // instead have the [Solver] ask each [Piece] for the cost of its state.
  final State _splitState;

  /// Whether this list should have spaces inside the bracket when it doesn't
  /// split. This is false for most lists, but true for switch expression
  /// bodies:
  ///
  /// ```
  /// v = switch (e) { 1 => 'one', 2 => 'two' };
  /// //              ^                      ^
  /// ```
  final bool _spaceWhenUnsplit;

  /// Whether a split in the [_before] piece should force the list to split too.
  /// Most of the time, this isn't relevant because the before part is usually
  /// just a single bracket character.
  ///
  /// For collection literals with explicit type arguments, the [_before] piece
  /// contains the type arguments. If those split, this is `false` to allow the
  /// list itself to remain unsplit as in:
  ///
  /// ```
  /// <
  ///   VeryLongTypeName,
  ///   AnotherLongTypeName,
  /// >{a: 1};
  /// ```
  ///
  /// For switch expressions, the `switch (value) {` part is in [_before] and
  /// the body is the list. In that case, if the value splits, we want to force
  /// the body to split too:
  ///
  /// ```
  /// // Disallowed:
  /// e = switch (
  ///   "a long string that must wrap"
  /// ) { 0 => "ok" };
  ///
  /// // Instead:
  /// e = switch (
  ///   "a long string that must wrap"
  /// ) {
  ///   0 => "ok",
  /// };
  /// ```
  final bool _splitListIfBeforeSplits;

  ListPiece(
      this._before,
      this._arguments,
      this._blanksAfter,
      this._after,
      int cost,
      this._trailingComma,
      this._spaceWhenUnsplit,
      this._splitListIfBeforeSplits)
      : _splitState = State(1, cost: cost);

  @override
  List<State> get additionalStates => [if (_arguments.isNotEmpty) _splitState];

  @override
  void format(CodeWriter writer, State state) {
    if (_splitListIfBeforeSplits && state == State.unsplit) {
      writer.setAllowNewlines(false);
    }

    writer.format(_before);

    // TODO(tall): Should support a third state for argument lists with block
    // arguments, like:
    //
    // ```
    // test('description', () {
    //   ...
    // });
    // ```
    if (state == State.unsplit) {
      writer.setAllowNewlines(false);
      if (_spaceWhenUnsplit && _arguments.isNotEmpty) writer.space();

      // All arguments on one line with no trailing comma.
      for (var i = 0; i < _arguments.length; i++) {
        if (i > 0 && _arguments[i - 1]._delimiter.isEmpty) writer.space();

        // Don't write a trailing comma.
        _arguments[i].format(writer, omitComma: i == _arguments.length - 1);
      }

      if (_spaceWhenUnsplit && _arguments.isNotEmpty) writer.space();
    } else {
      // Each argument on its own line with a trailing comma after the last.
      writer.newline(indent: Indent.block);
      for (var i = 0; i < _arguments.length; i++) {
        var argument = _arguments[i];
        argument.format(writer,
            omitComma: !_trailingComma && i == _arguments.length - 1);
        if (i < _arguments.length - 1) {
          writer.newline(blank: _blanksAfter.contains(argument));
        }
      }
      writer.newline(indent: Indent.none);
    }

    writer.setAllowNewlines(true);
    writer.format(_after);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_before);

    for (var argument in _arguments) {
      argument.forEachChild(callback);
    }

    callback(_after);
  }

  @override
  String toString() => 'Call';
}

/// An element in a [ListPiece].
///
/// Contains a piece for the element itself and a comment. Both are optional,
/// but at least one must be present. A [ListElement] containing only a comment
/// is used when a comment appears in a place where it gets formatted like a
/// standalone element. A [ListElement] containing both an element piece and a
/// comment piece represents an element with a hanging comment after the
/// (potentially ommitted) comma:
///
/// ```dart
/// function(
///   first,
///   // Standalone.
///   second, // Hanging.
/// ```
///
/// Here, `first` is a [ListElement] with only an element, `// Standalone.` is
/// a [ListElement] with only a comment, and `second, // Hanging.` is a
/// [ListElement] with both where `second` is the element and `// Hanging` is
/// the comment.
final class ListElement {
  final Piece? _element;

  /// If this piece has an opening delimiter after the comma, this is its
  /// lexeme, otherwise an empty string.
  ///
  /// This is only used for parameter lists when an optional or named parameter
  /// section begins in the middle of the parameter list, like:
  ///
  /// ```
  /// function(
  ///   int parameter1, [
  ///   int parameter2,
  /// ]);
  /// ```
  final String _delimiter;

  final Piece? _comment;

  ListElement(Piece element, [Piece? comment]) : this._(element, '', comment);

  ListElement.comment(Piece comment) : this._(null, '', comment);

  ListElement._(this._element, this._delimiter, [this._comment]);

  /// Writes this element to [writer].
  ///
  /// If this element could have a comma after it (because it's not just a
  /// comment) and [omitComma] is `false`, then elides the comma.
  void format(CodeWriter writer, {required bool omitComma}) {
    if (_element case var element?) {
      writer.format(element);
      if (!omitComma) writer.write(',');
      if (_delimiter.isNotEmpty) {
        writer.space();
        writer.write(_delimiter);
      }
    }

    if (_comment case var comment?) {
      if (_element != null) writer.space();
      writer.format(comment);
    }
  }

  void forEachChild(void Function(Piece piece) callback) {
    if (_element case var expression?) callback(expression);
    if (_comment case var comment?) callback(comment);
  }

  /// Returns a new [ListElement] containing this one's element and [comment].
  ListElement withComment(Piece comment) {
    assert(_comment == null); // Shouldn't already have one.
    return ListElement._(_element, _delimiter, comment);
  }

  ListElement withDelimiter(String delimiter) {
    return ListElement._(_element, delimiter, _comment);
  }
}
