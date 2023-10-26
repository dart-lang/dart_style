// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a splittable series of items.
///
/// Items may optionally be delimited with brackets and may have commas added
/// after elements.
///
/// Used for argument lists, collection literals, parameter lists, etc. This
/// class handles adding and removing the trailing comma depending on whether
/// the list is split or not. It handles comments inside the sequence of
/// elements.
///
/// Usually constructed using [createList()] or a [DelimitedListBuilder].
class ListPiece extends Piece {
  /// The opening bracket before the elements, if any.
  final Piece? _before;

  /// The list of elements.
  final List<ListElement> _elements;

  /// The elements that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElement> _blanksAfter;

  /// The closing bracket after the elements, if any.
  final Piece? _after;

  /// The details of how this particular list should be formatted.
  final ListStyle _style;

  /// The state when the list is split.
  ///
  /// We use this instead of [State.split] because the cost is higher for some
  /// kinds of lists.
  // TODO(rnystrom): Having to use a different state for this is a little
  // cumbersome. Maybe it would be better to most costs out of [State] and
  // instead have the [Solver] ask each [Piece] for the cost of its state.
  final State _splitState;

  ListPiece(
      this._before, this._elements, this._blanksAfter, this._after, this._style)
      : _splitState = State(1, cost: _style.splitCost);

  @override
  List<State> get additionalStates => [if (_elements.isNotEmpty) _splitState];

  @override
  void format(CodeWriter writer, State state) {
    // TODO(tall): Should support a third state for argument lists with block
    // arguments, like:
    //
    // ```
    // test('description', () {
    //   ...
    // });
    // ```

    // Format the opening bracket, if there is one.
    if (_before case var before?) {
      if (_style.splitListIfBeforeSplits && state == State.unsplit) {
        writer.setAllowNewlines(false);
      }

      writer.format(before);

      if (state == State.unsplit) writer.setAllowNewlines(false);

      // Whitespace after the opening bracket.
      writer.splitIf(state != State.unsplit,
          indent: Indent.block,
          space: _style.spaceWhenUnsplit && _elements.isNotEmpty);
    }

    // Format the elements.
    for (var i = 0; i < _elements.length; i++) {
      var isLast = i == _elements.length - 1;
      var appendComma = switch (_style.commas) {
        // Trailing comma after the last element if split but not otherwise.
        Commas.trailing => !(state == State.unsplit && isLast),
        // Never a trailing comma after the last element.
        Commas.nonTrailing => !isLast,
        Commas.none => false,
      };

      var element = _elements[i];
      element.format(writer, appendComma: appendComma);

      // Write a space or newline between elements.
      if (!isLast) {
        writer.splitIf(state != State.unsplit,
            blank: _blanksAfter.contains(element),
            // No space after the "[" or "{" in a parameter list.
            space: element._delimiter.isEmpty);
      }
    }

    // Format the closing bracket, if any.
    if (_after case var after?) {
      // Whitespace before the closing bracket.
      writer.splitIf(state != State.unsplit,
          indent: Indent.none,
          space: _style.spaceWhenUnsplit && _elements.isNotEmpty);

      writer.setAllowNewlines(true);
      writer.format(after);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_before case var before?) callback(before);

    for (var argument in _elements) {
      argument.forEachChild(callback);
    }

    if (_after case var after?) callback(after);
  }

  @override
  String toString() => 'List';
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
  /// If [appendComma] is `true`, writes a comma after the element, unless the
  /// element shouldn't have one because it's a comment.
  void format(CodeWriter writer, {required bool appendComma}) {
    if (_element case var element?) {
      writer.format(element);
      if (appendComma) writer.write(',');
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

/// Where commas should be added in a [ListPiece].
enum Commas {
  /// Add a comma after every element when the elements split, including the
  /// last. When not split, omit the trailing comma.
  trailing,

  /// Add a comme after every element except for the last, regardless of whether
  /// or not it is split.
  nonTrailing,

  /// Don't add commas after any elements.
  none,
}

/// The various ways a "list" can appear syntactically and be formatted.
///
/// [ListPiece] is used for most places in code where a series of elements can
/// be either all on one line or can be each split to their own line with no
/// extra indentation: argument lists, parameter lists, collection literals,
/// type arguments, switch expression cases, etc.
///
/// These have similar enough formatting to use the same class. And, in
/// particular, they all handle comments between elements the same way. But
/// they vary in whether or not a trailing comma is allowed, whether there
/// should be spaces inside the delimiters when the elements aren't split, etc.
/// This class captures those options.
class ListStyle {
  /// How commas should be handled by the list.
  ///
  /// Most lists use [Commas.trailing]. Type parameters and type arguments use
  /// [Commas.nonTrailing]. For loop parts and switch values use [Commas.none].
  final Commas commas;

  /// The cost of splitting this list. Normally 1, but higher for some lists
  /// that look worse when split.
  final int splitCost;

  /// Whether this list should have spaces inside the bracket when it doesn't
  /// split. This is false for most lists, but true for switch expression
  /// bodies:
  ///
  /// ```
  /// v = switch (e) { 1 => 'one', 2 => 'two' };
  /// //              ^                      ^
  /// ```
  final bool spaceWhenUnsplit;

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
  final bool splitListIfBeforeSplits;

  const ListStyle(
      {this.commas = Commas.trailing,
      this.splitCost = Cost.normal,
      this.spaceWhenUnsplit = false,
      this.splitListIfBeforeSplits = false});
}
