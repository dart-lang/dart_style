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
/// Usually constructed using a [DelimitedListBuilder].
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

  ListPiece(this._before, this._arguments, this._blanksAfter, this._after);

  /// Don't let the list split if there is nothing in it.
  @override
  List<State> get states => _arguments.isEmpty ? const [] : const [State.split];

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
      case State.initial:
        // All arguments on one line with no trailing comma.
        writer.setAllowNewlines(false);
        for (var i = 0; i < _arguments.length; i++) {
          if (i > 0) writer.space();

          // Don't write a trailing comma.
          _arguments[i].format(writer, omitComma: i == _arguments.length - 1);
        }

      case State.split:
        // Each argument on its own line with a trailing comma after the last.
        writer.setIndent(Indent.block);
        writer.newline();
        for (var i = 0; i < _arguments.length; i++) {
          var argument = _arguments[i];
          argument.format(writer, omitComma: false);
          if (i < _arguments.length - 1) {
            writer.newline(blank: _blanksAfter.contains(argument));
          }
        }
        writer.setIndent(Indent.none);
        writer.newline();
    }

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
  final Piece? _comment;

  ListElement(this._element, [this._comment]);

  ListElement.comment(this._comment) : _element = null;

  /// Writes this element to [writer].
  ///
  /// If this element could have a comma after it (because it's not just a
  /// comment) and [omitComma] is `false`, then elides the comma.
  void format(CodeWriter writer, {required bool omitComma}) {
    if (_element case var element?) {
      writer.format(element);
      if (!omitComma) writer.write(',');
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
    return ListElement(_element, comment);
  }
}
