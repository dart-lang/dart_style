// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import '../short/fast_hash.dart';

typedef Constrain = void Function(Piece other, State constrainedState);

typedef ConstrainShape = void Function(Piece other, Shape shape);

/// Base class for the formatter's internal representation used for line
/// splitting.
///
/// We visit the source AST and convert it to a tree of [Piece]s. This tree
/// roughly follows the AST but includes comments and is optimized for
/// formatting and line splitting. The final output is then determined by
/// deciding which pieces split and how.
// TODO: Just using FastHash for ids for debugging.
abstract class Piece extends FastHash {
  /// The ordered list of ways this piece may split.
  ///
  /// This is [State.unsplit], which all pieces support, followed by any other
  /// [additionalStates].
  List<State> get states {
    if (_pinnedState case var pinned?) return [pinned];
    return [State.unsplit, ...additionalStates];
  }

  /// The ordered list of all possible ways this piece could split.
  ///
  /// Piece subclasses should override this if they support being split in
  /// multiple different ways.
  ///
  /// Each piece determines what each [State] in the list represents, including
  /// the automatically included [State.unsplit]. The list returned by this
  /// function should be sorted so that earlier states in the list compare less
  /// than later states.
  List<State> get additionalStates => const [];

  /// If this piece has been pinned to a specific state, that state.
  ///
  /// This is used when a piece which otherwise supports multiple ways of
  /// splitting should be eagerly constrained to a specific splitting choice
  /// because of the context where it appears. For example, if conditional
  /// expressions are nested, then all of them are forced to split because it's
  /// too hard to read nested conditionals all on one line. We can express that
  /// by pinning the Piece used for a conditional expression to its split state
  /// when surrounded by or containing other conditionals.
  State? get pinnedState => _pinnedState;
  State? _pinnedState;

  /// Whether this piece or any of its children contain an explicit mandatory
  /// newline.
  ///
  /// This is lazily computed and cached for performance, so should only be
  /// accessed after all of the piece's children are known.
  late final bool containsNewline = _calculateContainsNewline();

  bool _calculateContainsNewline() {
    var anyHasNewline = false;

    forEachChild((child) {
      anyHasNewline |= child.containsNewline;
    });

    return anyHasNewline;
  }

  /// The total number of characters of content in this piece and all of its
  /// children.
  ///
  /// This is lazily computed and cached for performance, so should only be
  /// accessed after all of the piece's children are known.
  late final int totalCharacters = _calculateTotalCharacters();

  int _calculateTotalCharacters() {
    var total = 0;

    forEachChild((child) {
      total += child.totalCharacters;
    });

    return total;
  }

  /// Apply any constraints that this piece places on other pieces when this
  /// piece is bound to [state].
  ///
  /// A piece class can override this. For any child piece that it wants to
  /// constrain when this piece is in [state], call [constrain] and pass in the
  /// child piece and the state that child should be constrained to.
  void applyConstraints(State state, Constrain constrain) {}

  Shape shapeForState(State state) => Shape.other;

  void applyShapeConstraints(State state, ConstrainShape constrain) {}

  /// The actual piece that should be constrained when a [Shape] constraint is
  /// placed on this piece by a parent piece.
  ///
  /// This lets a piece transparently wrap some other piece and pass along any
  /// constraints placed on it without having to mirror the inner piece's
  /// states.
  Piece forwardShapeConstraint() => this;

  /// Given that this piece is in [state], use [writer] to produce its formatted
  /// output.
  void format(CodeWriter writer, State state);

  /// Invokes [callback] on each piece contained in this piece.
  void forEachChild(void Function(Piece piece) callback);

  /// If the piece can determine that it will always end up in a certain state
  /// given [pageWidth] and size metrics returned by calling [containsNewline]
  /// and [totalCharacters] on its children, then returns that [State].
  ///
  /// For example, a series of infix operators wider than a page will always
  /// split one per operator. If we can determine this eagerly just based on
  /// the size of the children and the page width, then we can pin the Piece to
  /// that State. That in turn heavily prunes the search space that the [Solver]
  /// is exploring. In practice, for large expressions, many of the outermost
  /// Pieces can be eagerly pinned to their fully split state. That avoids the
  /// Solver wasting a lot of time trying in vain to pack those outer Pieces
  /// into unsplit states when it's obvious just from the size of their contents
  /// that they'll have to split.
  ///
  /// If it's not possible to determine whether a piece will split from its
  /// metrics, this returns `null`.
  ///
  /// This is purely an optimization: Running the [Solver] without ever calling
  /// this and pinning the resulting [State] should yield the same formatting.
  /// It is up to the [Piece] subclasses overriding this to ensure that they
  /// only return a non-`null` [State] if the piece really would always be
  /// solved to the returned state given its children.
  State? fixedStateForPageWidth(int pageWidth) => null;

  /// The cost that this piece should apply to the solution when in [state].
  ///
  /// This is usually just the state's cost, but some pieces may want to tweak
  /// the cost in certain circumstances.
  // TODO(tall): Given that we have this API now, consider whether it makes
  // sense to remove the cost field from State entirely.
  int stateCost(State state) => state.cost;

  /// Forces this piece to always use [state].
  void pin(State state) {
    _pinnedState = state;

    // If this piece's pinned state constrains any child pieces, pin those too,
    // recursively.
    applyConstraints(state, (other, constrainedState) {
      other.pin(constrainedState);
    });

    applyShapeConstraints(state, (other, constrainedShape) {
      print('TODO: Implement shape constraining in pin()!');
    });
  }

  /// The name of this piece as it appears in debug output.
  ///
  /// By default, this is the class's name with `Piece` removed.
  String get debugName => runtimeType.toString().replaceAll('Piece', '');

  @override
  String toString() => '$debugName$id';
}

/// A simple atomic piece of code.
///
/// This may represent a series of tokens where no split can occur between them.
/// It may also contain one or more comments.
sealed class TextPiece extends Piece {
  /// RegExp that matches any valid Dart line terminator.
  static final _lineTerminatorPattern = RegExp(r'\r\n?|\n');

  /// The lines of text in this piece.
  ///
  /// Most [TextPieces] will contain only a single line, but a piece for a
  /// multi-line string or comment will have multiple lines. These are stored
  /// as separate lines instead of a single multi-line Dart String so that
  /// line endings are normalized and so that column calculation during line
  /// splitting calculates each line in the piece separately.
  final List<String> _lines = [''];

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionEnd;

  /// Append [text] to the end of this piece.
  ///
  /// If [text] may contain any newline characters, then [multiline] must be
  /// `true`.
  ///
  /// If [selectionStart] and/or [selectionEnd] are given, then notes that the
  /// corresponding selection markers appear that many code units from where
  /// [text] will be appended.
  void append(String text,
      {required bool multiline, int? selectionStart, int? selectionEnd}) {
    if (selectionStart != null) {
      _selectionStart = _adjustSelection(selectionStart);
    }

    if (selectionEnd != null) {
      _selectionEnd = _adjustSelection(selectionEnd);
    }

    if (multiline) {
      var lines = text.split(_lineTerminatorPattern);
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) _lines.add('');
        _lines.last += lines[i];
      }
    } else {
      _lines.last += text;
    }
  }

  /// Sets [selectionStart] to be [start] code units after the end of the
  /// current text in this piece.
  void startSelection(int start) {
    _selectionStart = _adjustSelection(start);
  }

  /// Sets [selectionEnd] to be [end] code units after the end of the
  /// current text in this piece.
  void endSelection(int end) {
    _selectionEnd = _adjustSelection(end);
  }

  /// Adjust [offset] by the current length of this [TextPiece].
  int _adjustSelection(int offset) {
    for (var line in _lines) {
      offset += line.length;
    }

    return offset;
  }

  void _formatSelection(CodeWriter writer) {
    if (_selectionStart case var start?) {
      writer.startSelection(start);
    }

    if (_selectionEnd case var end?) {
      writer.endSelection(end);
    }
  }

  void _formatLines(CodeWriter writer) {
    for (var i = 0; i < _lines.length; i++) {
      if (i > 0) writer.newline(flushLeft: i > 0);
      writer.write(_lines[i]);
    }
  }

  @override
  bool _calculateContainsNewline() => _lines.length > 1;

  @override
  int _calculateTotalCharacters() {
    var total = 0;

    for (var line in _lines) {
      total += line.length;
    }

    return total;
  }

  @override
  String toString() => '`${_lines.join('¬')}`';
}

/// [TextPiece] for non-comment source code that may have comments attached to
/// it.
class CodePiece extends TextPiece {
  /// Pieces for any comments that appear immediately before this code.
  final List<Piece> _leadingComments;

  /// Pieces for any comments that hang off the same line as this code.
  final List<Piece> _hangingComments = [];

  CodePiece([this._leadingComments = const []]);

  void addHangingComment(Piece comment) {
    _hangingComments.add(comment);
  }

  @override
  void format(CodeWriter writer, State state) {
    _formatSelection(writer);

    if (_leadingComments.isNotEmpty) {
      // Always put leading comments on a new line.
      writer.newline();

      for (var comment in _leadingComments) {
        writer.format(comment);
      }
    }

    _formatLines(writer);

    for (var comment in _hangingComments) {
      writer.space();
      writer.format(comment);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
    _hangingComments.forEach(callback);
  }
}

/// A [TextPiece] for a source code comment and the whitespace after it, if any.
class CommentPiece extends TextPiece {
  /// Whitespace at the end of the comment.
  final Whitespace _trailingWhitespace;

  CommentPiece([this._trailingWhitespace = Whitespace.none]);

  @override
  void format(CodeWriter writer, State state) {
    _formatSelection(writer);
    _formatLines(writer);
    writer.whitespace(_trailingWhitespace);
  }

  @override
  bool _calculateContainsNewline() =>
      _trailingWhitespace.hasNewline || super._calculateContainsNewline();

  @override
  void forEachChild(void Function(Piece piece) callback) {}
}

/// A piece that writes a single space.
class SpacePiece extends Piece {
  @override
  void forEachChild(void Function(Piece piece) callback) {}

  @override
  void format(CodeWriter writer, State state) {
    writer.space();
  }

  @override
  bool _calculateContainsNewline() => false;

  @override
  int _calculateTotalCharacters() => 1;
}

/// A state that a piece can be in.
///
/// Each state identifies one way that a piece can be split into multiple lines.
/// Each piece determines how its states are interpreted.
class State implements Comparable<State> {
  static const unsplit = State(0, cost: 0);

  /// The maximally split state a piece can be in.
  ///
  /// The value here is somewhat arbitrary. It just needs to be larger than
  /// any other value used by any [Piece] that uses this [State].
  static const split = State(255);

  final int _value;

  /// How much a solution is penalized when this state is chosen.
  final int cost;

  const State(this._value, {this.cost = 1});

  @override
  int compareTo(State other) => _value.compareTo(other._value);

  @override
  String toString() => '◦$_value';
}
