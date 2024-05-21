// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A piece for a non-empty splittable series of items.
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
  final List<ListElementPiece> _elements;

  /// The elements that should have a blank line preserved between them and the
  /// next piece.
  final Set<ListElementPiece> _blanksAfter;

  /// The closing bracket after the elements, if any.
  final Piece? _after;

  /// The details of how this particular list should be formatted.
  final ListStyle _style;

  /// Whether any element in this argument list can be block formatted.
  bool get hasBlockElement =>
      _elements.any((element) => element.allowNewlinesWhenUnsplit);

  /// Creates a new [ListPiece].
  ///
  /// [_elements] must not be empty. (If there are no elements, just concatenate
  /// the brackets directly.)
  ListPiece(
      this._before, this._elements, this._blanksAfter, this._after, this._style)
      : assert(_elements.isNotEmpty) {
    // For most elements, we know whether or not it will have a comma based
    // only on the comma style and its position in the list, so pin those here.
    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];

      switch (_style.commas) {
        case Commas.alwaysTrailing:
          // Has a comma after every element.
          element.pin(ListElementPiece._appendComma);

        case Commas.trailing:
          // Always has a comma after every element except the last. The last
          // will be constrained to have one or not depending on whether the
          // list splits. See applyConstraints().
          if (i < _elements.length - 1) {
            element.pin(ListElementPiece._appendComma);
          }

        case Commas.nonTrailing:
          // Never a trailing comma after the last element.
          element.pin(i < _elements.length - 1
              ? ListElementPiece._appendComma
              : State.unsplit);

        case Commas.none:
          // No comma after any element.
          element.pin(State.unsplit);
      }
    }
  }

  @override
  List<State> get additionalStates => const [State.split];

  @override
  void applyConstraints(State state, Constrain constrain) {
    // Give the last element a trailing comma only if the list is split.
    if (_style.commas == Commas.trailing) {
      constrain(_elements.last,
          state == State.split ? ListElementPiece._appendComma : State.unsplit);
    }
  }

  @override
  int stateCost(State state) {
    if (state == State.split) return _style.splitCost;
    return super.stateCost(state);
  }

  @override
  bool allowNewlineInChild(State state, Piece child) {
    if (state == State.split) return true;
    if (child == _before) return true;
    if (child == _after) return true;

    // Only some elements (usually a single block element) allow newlines
    // when the list itself isn't split.
    return child is ListElementPiece && child.allowNewlinesWhenUnsplit;
  }

  @override
  void format(CodeWriter writer, State state) {
    // Format the opening bracket, if there is one.
    if (_before case var before?) {
      writer.format(before);

      if (state != State.unsplit) writer.pushIndent(Indent.block);

      // Whitespace after the opening bracket.
      writer.splitIf(state == State.split,
          space: _style.spaceWhenUnsplit && _elements.isNotEmpty);
    }

    // Format the elements.
    for (var i = 0; i < _elements.length; i++) {
      var element = _elements[i];

      // If this element allows newlines when the list isn't split, add
      // indentation if it requires it.
      if (state == State.unsplit && element.indentWhenBlockFormatted) {
        writer.pushIndent(Indent.expression);
      }

      // We can format each list item separately if the item is on its own line.
      // This happens when the list is split and there is something before and
      // after the item, either brackets or other items.
      var separate = state == State.split &&
          (i > 0 || _before != null) &&
          (i < _elements.length - 1 || _after != null);
      writer.format(element, separate: separate);

      if (state == State.unsplit && element.indentWhenBlockFormatted) {
        writer.popIndent();
      }

      // Write a space or newline between elements.
      if (i < _elements.length - 1) {
        writer.splitIf(state == State.split,
            blank: _blanksAfter.contains(element),
            // No space after the "[" or "{" in a parameter list.
            space: element._delimiter.isEmpty);
      }
    }

    // Format the closing bracket, if any.
    if (_after case var after?) {
      if (state == State.split) writer.popIndent();

      // Whitespace before the closing bracket.
      writer.splitIf(state == State.split,
          space: _style.spaceWhenUnsplit && _elements.isNotEmpty);

      writer.format(after);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    if (_before case var before?) callback(before);

    for (var element in _elements) {
      callback(element);
    }

    if (_after case var after?) callback(after);
  }

  @override
  State? fixedStateForPageWidth(int pageWidth) {
    var totalLength = 0;
    if (_before case var before?) {
      // A newline in the opening bracket (like a line comment after the
      // bracket) forces the list to split.
      if (before.containsHardNewline) return State.split;
      totalLength += before.totalCharacters;
    }

    for (var element in _elements) {
      // Elements that can be block arguments won't necessarily force the list
      // to split.
      if (element.allowNewlinesWhenUnsplit) continue;

      if (element.containsHardNewline) return State.split;
      totalLength += element.totalCharacters;
      if (totalLength > pageWidth) break;
    }

    if (_after case var after?) {
      totalLength += after.totalCharacters;

      // Note that a newline in `_after` does *not* force the list to split, so
      // we ignore it here. This is typically a line comment after the closing
      // bracket.
    }

    // If the entire list doesn't fit on one line, it will split.
    if (totalLength >= pageWidth) return State.split;

    return null;
  }
}

/// An element in a [ListPiece].
///
/// Contains any leading inline comments, the element's code content, and
/// trailing comments.
///
/// Leading and trailing comments may be empty if there are no comments. The
/// content may be empty when the element piece represents a comment that is on
/// its own line and formatted like a standalone element. In that case,
/// [_hangingComments] will contain the comment.
///
/// This piece also handles writing the comma after the content (but before any
/// hanging comments) when appropriate. The split state of the surrounding list
/// often determines whether the last element's trailing comma is shown. To
/// handle that, this piece has two states: [State.unsplit] omits the comma and
/// [_appendComma] writes it. The parent [ListPiece] will pin or constrain its
/// child elements appropriately to control whether or not the comma is written.
final class ListElementPiece extends Piece {
  static const State _appendComma = State(1, cost: 0);

  /// The leading inline block comments before the content.
  final List<Piece> _leadingComments;

  final Piece? _content;

  /// What kind of block formatting can be applied to this element.
  final BlockFormat blockFormat;

  /// Whether newlines are allowed in this element when this list is unsplit.
  ///
  /// This is generally only true for a single "block" element, as in:
  ///
  ///     function(argument, [
  ///       block,
  ///       element,
  ///     ], another);
  bool allowNewlinesWhenUnsplit = false;

  /// Whether we should increase indentation when formatting this element when
  /// the list isn't split.
  ///
  /// This only comes into play for unsplit lists and is only relevant when the
  /// element contains newlines, which means that this is only ever useful when
  /// [allowNewlinesWhenUnsplit] is also true.
  ///
  /// This is used for adjacent strings expression at the beginning of an
  /// argument list followed by a function expression, like in a `test()` call.
  /// Since the adjacent strings may not require indentation when the list is
  /// fully split, this ensures that they are indented properly when the list
  /// isn't split. Avoids:
  //
  //     test('long description'
  //     'that should be indented', () {
  //       body;
  //     });
  bool indentWhenBlockFormatted = false;

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

  ListElementPiece(
      List<Piece> leadingComments, Piece element, BlockFormat format)
      : _leadingComments = [...leadingComments],
        _content = element,
        blockFormat = format;

  ListElementPiece.comment(Piece comment)
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

  @override
  void format(CodeWriter writer, State state) {
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

      if (state == _appendComma) writer.write(',');

      if (_delimiter.isNotEmpty) {
        writer.space();
        writer.write(_delimiter);
      }
    }

    for (var i = _commentsBeforeDelimiter; i < _hangingComments.length; i++) {
      if (i > 0 || _content != null) writer.space();
      writer.format(_hangingComments[i]);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
    if (_content case var content?) callback(content);
    _hangingComments.forEach(callback);
  }

  @override
  void preventSplit() {
    // Don't pin the ListElementPiece. Its state is only used to determine
    // whether or not to write a comma.
  }

  @override
  String get debugName => 'ListElem';
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
  /// The element is a function expression or immediately invoked function
  /// expression, which takes priority over other kinds of block formatted
  /// elements.
  function,

  /// The element is a collection literal.
  ///
  /// These can be block formatted even when there are other arguments.
  collection,

  /// A function or method invocation.
  ///
  /// We only allow block formatting these if there are no other arguments.
  invocation,

  /// The element is an adjacent strings expression that's in an list that
  /// requires its subsequent lines to be indented (because there are other
  /// string literal in the list).
  indentedAdjacentStrings,

  /// The element is an adjacent strings expression that's in an list that
  /// doesn't require its subsequent lines to be indented (because there
  /// are no other string literals in the list).
  unindentedAdjacentStrings,

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
      this.allowBlockElement = false});
}
