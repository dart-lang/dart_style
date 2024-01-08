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
/// These pieces can be formatted in one of three ways:
///
/// [State.split] Fully unsplit:
///
///     function(argument, argument, argument);
///
/// If one of the elements is a "block element", then we allow newlines inside
/// it to support output like:
///
///     function(argument, () {
///       blockElement;
///     }, argument);
///
/// [_splitState] Split around all of the items:
///
///     function(
///       argument,
///       argument,
///       argument,
///     );
///
/// ListPieces are usually constructed using [createList()] or
/// [DelimitedListBuilder].
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

  /// If this list has an element that can receive block formatting, this is
  /// the elements's index. Otherwise `-1`.
  final int _blockElement;

  ListPiece(this._before, this._elements, this._blanksAfter, this._after,
      this._style, this._blockElement);

  @override
  List<State> get additionalStates => [if (_elements.isNotEmpty) State.split];

  @override
  int stateCost(State state) {
    if (state == State.split) return _style.splitCost;
    return super.stateCost(state);
  }

  @override
  void format(CodeWriter writer, State state) {
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
        // Has a comma after every element.
        Commas.alwaysTrailing => true,
        // Trailing comma after the last element if split but not otherwise.
        Commas.trailing => !(state == State.unsplit && isLast),
        // Never a trailing comma after the last element.
        Commas.nonTrailing => !isLast,
        Commas.none => false,
      };

      // Only allow newlines in the block element or in all elements if we're
      // fully split.
      writer.setAllowNewlines(i == _blockElement || state == State.split);

      var element = _elements[i];
      element.format(writer,
          appendComma: appendComma,
          // Only allow newlines in comments if we're fully split.
          allowNewlinesInComments: state == State.split);

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
///     function(
///       first,
///       // Standalone.
///       second, // Hanging.
///
/// Here, `first` is a [ListElement] with only an element, `// Standalone.` is
/// a [ListElement] with only a comment, and `second, // Hanging.` is a
/// [ListElement] with both where `second` is the element and `// Hanging` is
/// the comment.
final class ListElement {
  /// The leading inline block comments before the content.
  final List<Piece> _leadingComments;

  final Piece? _content;

  /// What kind of block formatting can be applied to this element.
  final BlockFormat blockFormat;

  /// If this piece has an opening delimiter after the comma, this is its
  /// lexeme, otherwise an empty string.
  ///
  /// This is only used for parameter lists when an optional or named parameter
  /// section begins in the middle of the parameter list, like:
  ///
  ///     function(
  ///       int parameter1, [
  ///       int parameter2,
  ///     ]);
  String _delimiter = '';

  /// The hanging inline block and line comments that appear after the content.
  final List<Piece> _hangingComments = [];

  /// The number of hanging comments that should appear before the delimiter.
  ///
  /// A list item may have hanging comments before and after the delimiter, as
  /// in:
  ///
  ///     function(
  ///       argument /* 1 */ /* 2 */, /* 3 */ /* 4 */ // 5
  ///     );
  ///
  /// This field counts the number of comments that should be before the
  /// delimiter (here `,` and 2).
  int _commentsBeforeDelimiter = 0;

  ListElement(List<Piece> leadingComments, Piece element, BlockFormat format)
      : _leadingComments = [...leadingComments],
        _content = element,
        blockFormat = format;

  ListElement.comment(Piece comment)
      : _leadingComments = const [],
        _content = null,
        blockFormat = BlockFormat.none {
    _hangingComments.add(comment);
  }

  void addComment(Piece comment, {bool beforeDelimiter = false}) {
    _hangingComments.add(comment);
    if (beforeDelimiter) _commentsBeforeDelimiter++;
  }

  void setDelimiter(String delimiter) {
    _delimiter = delimiter;
  }

  void format(CodeWriter writer,
      {required bool appendComma, required bool allowNewlinesInComments}) {
    for (var comment in _leadingComments) {
      writer.format(comment);
      writer.space();
    }

    if (_content case var content?) {
      writer.format(content);

      for (var i = 0; i < _commentsBeforeDelimiter; i++) {
        writer.space();
        writer.format(_hangingComments[i]);
      }

      if (appendComma) writer.write(',');

      if (_delimiter.isNotEmpty) {
        writer.space();
        writer.write(_delimiter);
      }
    }

    writer.setAllowNewlines(allowNewlinesInComments);

    for (var i = _commentsBeforeDelimiter; i < _hangingComments.length; i++) {
      if (i > 0 || _content != null) writer.space();
      writer.format(_hangingComments[i]);
    }
  }

  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
    if (_content case var content?) callback(content);
    _hangingComments.forEach(callback);
  }
}

/// Where commas should be added in a [ListPiece].
enum Commas {
  /// Add a comma after every element, regardless of whether or not it is split.
  alwaysTrailing,

  /// Add a comma after every element when the elements split, including the
  /// last. When not split, omit the trailing comma.
  trailing,

  /// Add a comma after every element except for the last, regardless of whether
  /// or not it is split.
  nonTrailing,

  /// Don't add commas after any elements.
  none,
}

/// What kind of block formatting style can be applied to the element.
enum BlockFormat {
  /// The element is a function expression, which takes priority over other
  /// kinds of block formatted elements.
  function,

  /// The element is a collection literal or some other kind expression that
  /// can be block formatted.
  block,

  /// The element can't be block formatted.
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
  ///     v = switch (e) { 1 => 'one', 2 => 'two' };
  ///     //              ^                      ^
  final bool spaceWhenUnsplit;

  /// Whether a split in the [_before] piece should force the list to split too.
  /// Most of the time, this isn't relevant because the before part is usually
  /// just a single bracket character.
  ///
  /// For collection literals with explicit type arguments, the [_before] piece
  /// contains the type arguments. If those split, this is `false` to allow the
  /// list itself to remain unsplit as in:
  ///
  ///     <
  ///       VeryLongTypeName,
  ///       AnotherLongTypeName,
  ///     >{a: 1};
  ///
  /// For switch expressions, the `switch (value) {` part is in [_before] and
  /// the body is the list. In that case, if the value splits, we want to force
  /// the body to split too:
  ///
  ///     // Disallowed:
  ///     e = switch (
  ///       "a long string that must wrap"
  ///     ) { 0 => "ok" };
  ///
  ///     // Instead:
  ///     e = switch (
  ///       "a long string that must wrap"
  ///     ) {
  ///       0 => "ok",
  ///     };
  final bool splitListIfBeforeSplits;

  /// Whether an element in the list is allowed to have block-like formatting,
  /// as in:
  ///
  ///     function(argument, [
  ///       block,
  ///       like,
  ///     ], argument);
  final bool allowBlockElement;

  const ListStyle(
      {this.commas = Commas.trailing,
      this.splitCost = Cost.normal,
      this.spaceWhenUnsplit = false,
      this.splitListIfBeforeSplits = false,
      this.allowBlockElement = false});
}
