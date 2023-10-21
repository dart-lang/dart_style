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
  /// State used for a split list containing type arguments or type parameters.
  ///
  /// Has a higher cost than [State.split] since splitting type arguments and
  /// type parameters tends to look worse than splitting at other places.
  // TODO(rnystrom): Having to use a different state for this is a little
  // cumbersome. Maybe it would be better to most costs out of [State] and
  // instead have the [Solver] ask each [Piece] for the cost of its state.
  static const _splitTypes = State(1, cost: 2);

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

  /// Whether this list is a list of type arguments or type parameters, versus
  /// any other kind of list.
  ///
  /// Type arguments/parameters are different because:
  ///
  /// *   The language doesn't allow a trailing comma in them.
  /// *   Splitting in them looks aesthetically worse, so we increase the cost
  ///     of doing so.
  final bool _isTypeList;

  ListPiece(this._before, this._arguments, this._blanksAfter, this._after,
      this._isTypeList);

  @override
  List<State> get additionalStates => [
        if (_isTypeList)
          _splitTypes // Type lists are more expensive to split.
        else if (_arguments.isNotEmpty)
          State.split // Don't split between an empty pair of brackets.
      ];

  @override
  void format(CodeWriter writer, State state) {
    writer.format(_before);

    // TODO(tall): Should support a third state for argument lists with block
    // arguments, like:
    //
    // ```
    // test('description', () {
    //   ...
    // });
    // ```
    switch (state) {
      case State.unsplit:
        // All arguments on one line with no trailing comma.
        writer.setAllowNewlines(false);
        for (var i = 0; i < _arguments.length; i++) {
          if (i > 0 && _arguments[i - 1]._delimiter.isEmpty) writer.space();

          // Don't write a trailing comma.
          _arguments[i].format(writer, omitComma: i == _arguments.length - 1);
        }

      case State.split:
      case _splitTypes:
        // Each argument on its own line with a trailing comma after the last.
        writer.newline(indent: Indent.block);
        for (var i = 0; i < _arguments.length; i++) {
          var argument = _arguments[i];
          argument.format(writer,
              omitComma: _isTypeList && i == _arguments.length - 1);
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
