// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:math';

import '../debug.dart' as debug;
import '../piece/piece.dart';
import '../profile.dart';
import 'code.dart';
import 'solution.dart';
import 'solution_cache.dart';

/// The interface used by [Piece]s to output formatted code.
///
/// The back-end lowers the tree of pieces to the final formatted code by
/// allowing each piece to produce the output for the code it represents.
/// This way, each piece has full flexibility for how to apply its own
/// formatting logic.
///
/// To build the resulting output code, when a piece is formatted, it is passed
/// an instance of this class. It has methods that the piece can call to add
/// output text to the resulting code, recursively format child pieces, insert
/// whitespace, etc.
final class CodeWriter {
  final int _pageWidth;

  /// Previously cached formatted subtrees.
  final SolutionCache _cache;

  /// The solution this [CodeWriter] is generating code for.
  final Solution _solution;

  /// The code being written.
  final GroupCode _code;

  /// What whitespace should be written before the next non-whitespace text.
  ///
  /// When whitespace is written, instead of immediately writing it, we queue
  /// it as pending. This ensures that we don't write trailing whitespace,
  /// avoids writing spaces at the beginning of lines, and allows collapsing
  /// multiple redundant newlines.
  ///
  /// Initially [Whitespace.newline] so that we write the leading indentation
  /// before the first token.
  Whitespace _pendingWhitespace = Whitespace.none;

  /// The number of spaces of indentation that should be begin the next line
  /// when [_pendingWhitespace] is [Whitespace.newline] or
  /// [Whitespace.blankLine].
  int _pendingIndent = 0;

  /// The number of characters in the line currently being written.
  int _column = 0;

  /// The stack of indentation levels.
  ///
  /// Each entry in the stack is the absolute number of spaces of leading
  /// indentation that should be written when beginning a new line to account
  /// for block nesting, expression wrapping, constructor initializers, etc.
  final List<_IndentLevel> _indentStack = [];

  /// The stack of information for each [Piece] currently being formatted.
  ///
  /// This allows [CodeWriter] to pass itself data from parent to child through
  /// [format()] calls and back up from child to parent without every override
  /// of [format()] having to thread that data through.
  final List<_FormatState> _pieceFormats = [];

  /// Whether we have already found the first line where whose piece should be
  /// used to expand further solutions.
  ///
  /// This is the first line that either overflows or contains an invalid
  /// newline. When expanding solutions, we use the first solvable piece on
  /// this line.
  bool _foundExpandLine = false;

  /// The solvable pieces on the first overflowing or invalid line, if we've
  /// found any.
  ///
  /// A piece is "solvable" if we haven't already bound it to a state and there
  /// are multiple states it accepts. This is the piece whose states will be
  /// bound when we expand the [Solution] that this [CodeWriter] is building
  /// into further solutions.
  ///
  /// If [_foundExpandLine] is `true`, then this contains the list of unsolved
  /// pieces that were being formatted when text was written to the first
  /// problematic line.
  final List<Piece> _expandPieces = [];

  /// The stack of solvable pieces currently being formatted.
  ///
  /// We use this to track which pieces are in play when text is written to the
  /// current line so that we know which piece should be expanded in the next
  /// solution if the line ends up overflowing.
  final List<Piece> _currentUnsolvedPieces = [];

  /// The set of unsolved pieces that were being formatted when text was
  /// written to the current line.
  final Set<Piece> _currentLinePieces = {};

  /// [leadingIndent] is the number of spaces of leading indentation at the
  /// beginning of the first line and [subsequentIndent] is the indentation of
  /// each line after that, independent of indentation created by pieces being
  /// written.
  CodeWriter(
    this._pageWidth,
    int leadingIndent,
    int subsequentIndent,
    this._cache,
    this._solution,
  ) : _code = GroupCode(leadingIndent) {
    _indentStack.add(_IndentLevel(Indent.none, leadingIndent));

    // Track the leading indent before the first line.
    _pendingIndent = leadingIndent;
    _column = _pendingIndent;

    // If there is additional indentation on subsequent lines, then push that
    // onto the stack. When the first newline is written, [_pendingIndent] will
    // pick this up and use it for subsequent lines.
    if (subsequentIndent > leadingIndent) {
      _indentStack.add(_IndentLevel(Indent.none, subsequentIndent));
    }
  }

  /// Returns the final formatted code and the next pieces that can be expanded
  /// from the solution this [CodeWriter] is writing, if any.
  (GroupCode, List<Piece>) finish() {
    _finishLine();

    return (_code, _expandPieces);
  }

  /// Appends [text] to the output.
  ///
  /// If [text] contains any internal newlines, the caller is responsible for
  /// also calling [handleNewline()].
  ///
  /// When possible, avoid calling this directly. Instead, any input code
  /// lexemes should be written to TextPieces which then call this. That way,
  /// selections inside lexemes are correctly updated.
  void write(String text) {
    _flushWhitespace();
    _code.write(text);
    _column += text.length;

    // If we haven't found an overflowing line yet, then this line might be one
    // so keep track of the unsolved pieces we've encountered on it.
    if (!_foundExpandLine) {
      _currentLinePieces.addAll(_currentUnsolvedPieces);
    }
  }

  /// Increases the indentation by [indent] relative to the current amount of
  /// indentation.
  void pushIndent(Indent indent) {
    if (_cache.isVersion37) {
      _pushIndentV37(indent);
    } else {
      var parent = _indentStack.last;

      // Combine the new indentation with the surrounding one.
      var offset = switch ((parent.type, indent)) {
        // On the right-hand side of `=`, `:`, or `=>`, don't indent subsequent
        // infix operands so that they all align:
        //
        //     variable =
        //         operand +
        //         another;
        (Indent.assignment, Indent.infix) => 0,

        // We have already indented the control flow header, so collapse the
        // duplicate indentation.
        (Indent.controlFlowClause, Indent.expression) => 0,
        (Indent.controlFlowClause, Indent.infix) => 0,

        // If we get here, the parent context has no effect, so just apply the
        // indentation directly.
        (_, _) => indent.spaces,
      };

      _indentStack.add(_IndentLevel(indent, parent.spaces + offset));
      if (debug.traceIndent) {
        debug.log('pushIndent: ${_indentStack.join(' ')}');
      }
    }
  }

  /// Increases the indentation in a control flow clause in a "collapsible" way.
  ///
  /// This is only used in a couple of corners of if-case and for-in headers
  /// where the indentation is unusual.
  void pushCollapsibleIndent() {
    if (_cache.isVersion37) {
      _pushIndentV37(Indent.expression, canCollapse: true);
    } else {
      pushIndent(Indent.controlFlowClause);
    }
  }

  /// The 3.7 style of indentation and collapsible indentation tracking.
  ///
  /// Splits in if-case and for-in loop headers are tricky to indent gracefully.
  /// For example, if an infix expression inside the case splits, we don't want
  /// it to be double indented:
  ///
  ///     if (object
  ///         case veryLongConstant
  ///                 as VeryLongType) {
  ///       ;
  ///     }
  ///
  /// That suggests that the [IfCasePiece] shouldn't add indentation for the
  /// case pattern since the [InfixPiece] inside it will already indent the RHS.
  ///
  /// But if the case is a variable pattern that splits, the [VariablePiece]
  /// does *not* add indentation because in most other places where it occurs,
  /// that's what we want. If the [IfCasePiece] doesn't indent the pattern, you
  /// get:
  ///
  ///     if (object
  ///         case VeryLongType
  ///         veryLongVariable
  ///         ) {
  ///       ;
  ///     }
  ///
  /// To deal with this, 3.7 had a notion of "collapsible" indentation. In 3.8
  /// and later, there is a different mechanism for merging indentation kinds.
  /// This function implements the former.
  void _pushIndentV37(Indent indent, {bool canCollapse = false}) {
    var parentIndent = _indentStack.last.spaces;
    var parentCollapse = _indentStack.last.collapsible;

    if (parentCollapse == indent.spaces) {
      // We're indenting by the same existing collapsible amount, so collapse
      // this new indentation with that existing one.
      _indentStack.add(_IndentLevel.v37(parentIndent, 0));
    } else if (canCollapse) {
      // We should never get multiple levels of nested collapsible indentation.
      assert(parentCollapse == 0);

      // Increase the indentation and note that it can be collapsed with
      // further indentation.
      _indentStack.add(
        _IndentLevel.v37(parentIndent + indent.spaces, indent.spaces),
      );
    } else {
      // Regular indentation, so just increase the indent.
      _indentStack.add(_IndentLevel.v37(parentIndent + indent.spaces, 0));
    }
  }

  /// Discards the indentation change from the last call to [pushIndent()].
  void popIndent() {
    _indentStack.removeLast();
  }

  /// Inserts a newline if [condition] is true.
  ///
  /// If [space] is `true` and [condition] is `false`, writes a space.
  ///
  /// If [blank] is `true`, writes an extra newline to produce a blank line.
  void splitIf(bool condition, {bool space = true, bool blank = false}) {
    if (condition) {
      newline(blank: blank);
    } else if (space) {
      this.space();
    }
  }

  /// Writes a single space to the output.
  void space() {
    whitespace(Whitespace.space);
  }

  /// Inserts a line split in the output.
  ///
  /// If [blank] is `true`, writes an extra newline to produce a blank line.
  ///
  /// If [flushLeft] is `true`, then the new line begins at column 1 and ignores
  /// any surrounding indentation. This is used for multi-line block comments
  /// and multi-line strings.
  void newline({bool blank = false, bool flushLeft = false}) {
    whitespace(
      blank ? Whitespace.blankLine : Whitespace.newline,
      flushLeft: flushLeft,
    );
  }

  /// Queues [whitespace] to be written to the output.
  ///
  /// If any non-whitespace is written after this call, then this whitespace
  /// will be written first. Also handles merging multiple kinds of whitespace
  /// intelligently together.
  ///
  /// If [flushLeft] is `true`, then the new line begins at column 1 and ignores
  /// any surrounding indentation. This is used for multi-line block comments
  /// and multi-line strings.
  void whitespace(Whitespace whitespace, {bool flushLeft = false}) {
    if (whitespace case Whitespace.newline || Whitespace.blankLine) {
      _applyNewlineToShape(_pieceFormats.last);
      _pendingIndent = flushLeft ? 0 : _indentStack.last.spaces;
    }

    _pendingWhitespace = _pendingWhitespace.collapse(whitespace);
  }

  /// When a newline is written by the current piece of one of its children,
  /// determines how that affects the current piece's shape.
  void setShapeMode(ShapeMode mode) {
    _pieceFormats.last.mode = mode;
  }

  /// Format [piece] and insert the result into the code being written and
  /// returned by [finish()].
  ///
  /// If [separate] is `true`, then [piece] is formatted and solved using a
  /// separate Solver and the result inserted into this CodeWriter's Solution.
  /// This lets us solve branches of the piece tree separately and compose the
  /// optimal results together.
  ///
  /// It's only safe to pass [separate] when the piece's formatting depends
  /// only on its starting indentation and state. If the piece's formatting can
  /// be affected by the contents of the current line, the contents after the
  /// piece's ending line, or constraints between pieces, then [separate] should
  /// be `false`. It's up to the parent piece to only call this when it's safe
  /// to do so. In practice, this usually means when the parent piece knows that
  /// [piece] will have a newline before and after it.
  void format(Piece piece, {bool separate = false}) {
    if (separate) {
      Profile.count('CodeWriter.format() piece separate');
      _formatSeparate(piece);
    } else {
      Profile.count('CodeWriter.format() piece inline');
      _formatInline(piece);
    }
  }

  /// Format [piece] using a separate [Solver] and merge the result into this
  /// writer's [_solution].
  void _formatSeparate(Piece piece) {
    var solution = _cache.find(
      piece,
      _solution.pieceStateIfBound(piece),
      pageWidth: _pageWidth,
      indent: _pendingIndent,
      subsequentIndent: _indentStack.last.spaces,
    );

    _pendingIndent = 0;
    _flushWhitespace();

    _solution.mergeSubtree(solution);
    _code.group(solution.code);
  }

  /// Format [piece] writing directly into this [CodeWriter].
  void _formatInline(Piece piece) {
    var isUnsolved =
        !_solution.isBound(piece) && piece.additionalStates.isNotEmpty;

    // See if we can immediately bind it based on the page width and the piece's
    // contents.
    if (isUnsolved) {
      // If the solution doesn't bind the piece already, we may be able to
      // eagerly bind it to a state knowing just the page width (minus any
      // leading indentation). If so, do that now. We do that here instead of
      // pinning the pieces because doing so here lets us take leading
      // indication into account which may vary based on the surrounding pieces
      // when we get here.
      Profile.begin('CodeWriter try to bind by page width');
      isUnsolved =
          !_solution.tryBindByPageWidth(
            piece,
            _pageWidth - _indentStack.first.spaces,
          );
      Profile.end('CodeWriter try to bind by page width');
    }

    if (isUnsolved) _currentUnsolvedPieces.add(piece);

    // Begin a new formatting context for this child.
    _pieceFormats.add(_FormatState(piece));

    // Format the child piece.
    piece.format(this, _solution.pieceState(piece));

    var child = _pieceFormats.removeLast();

    // Restore the surrounding piece's context.
    if (isUnsolved) _currentUnsolvedPieces.removeLast();

    // Now that we know the child's shape, see if the parent permits it.
    if (_pieceFormats.lastOrNull case var parent?) {
      var allowedShapes = parent.piece.allowedChildShapes(
        _solution.pieceState(parent.piece),
        child.piece,
      );

      bool invalid;
      if (_cache.isVersion37) {
        // If the child must be inline, then invalidate because we know it
        // contains some kind of newline.
        // TODO(rnystrom): It would be better if this logic wasn't different for
        // 3.7. The only place where the distinction between this code and the
        // logic in the else clause comes into play is with CaseExpressionPiece.
        invalid =
            child.shape != Shape.inline &&
            allowedShapes.length == 1 &&
            allowedShapes.contains(Shape.inline);
      } else {
        invalid = !allowedShapes.contains(child.shape);
      }

      if (invalid) _solution.invalidate(parent.piece);

      // If the child had newlines, propagate that to the parent's shape.
      if (child.shape != Shape.inline) {
        _applyNewlineToShape(parent, child.shape);
      }
    }
  }

  /// Sets [selectionStart] to be [start] code units into the output.
  void startSelection(int start) {
    _flushWhitespace();
    _code.startSelection(start);
  }

  /// Sets [selectionEnd] to be [end] code units into the output.
  void endSelection(int end) {
    _flushWhitespace();
    _code.endSelection(end);
  }

  /// Disables or re-enables formatting in a region of code.
  void setFormattingEnabled(bool enabled, int sourceOffset) {
    _code.setFormattingEnabled(enabled, sourceOffset);
  }

  /// Write any pending whitespace.
  ///
  /// This is called before non-whitespace text is about to be written, or
  /// before the selection is updated since the latter requires an accurate
  /// count of the written text, including whitespace.
  void _flushWhitespace() {
    switch (_pendingWhitespace) {
      case Whitespace.none:
        break; // Nothing to do.

      case Whitespace.newline:
      case Whitespace.blankLine:
        _finishLine();
        _column = _pendingIndent;
        _code.newline(
          blank: _pendingWhitespace == Whitespace.blankLine,
          indent: _column,
        );

      case Whitespace.space:
        _code.write(' ');
        _column++;
    }

    _pendingWhitespace = Whitespace.none;
  }

  void _finishLine() {
    // If the completed line is too long, track the overflow.
    if (_column >= _pageWidth) {
      _solution.addOverflow(_column - _pageWidth);
    }

    // If we found a problematic line, and there is are pieces on the line that
    // we can try to split, then remember them so that the solution will expand
    // them next.
    if (_foundExpandLine) return;
    if (_currentLinePieces.isNotEmpty &&
        (_column > _pageWidth || !_solution.isValid)) {
      _expandPieces.addAll(_currentLinePieces);
      _foundExpandLine = true;
    } else {
      // This line was OK, so we don't need to expand the pieces on it.
      _currentLinePieces.clear();
    }
  }

  /// Determine how a newline affects the current piece's shape.
  void _applyNewlineToShape(_FormatState state, [Shape shape = Shape.other]) {
    state.shape = switch (state.mode) {
      ShapeMode.merge => state.shape.merge(shape),
      ShapeMode.block => Shape.block,
      ShapeMode.beforeHeadline => Shape.other,
      // If there were no newlines inside the headline, now that there is one,
      // we have a headline shape.
      ShapeMode.afterHeadline when state.shape == Shape.inline =>
        Shape.headline,
      // If there was already a newline in the headline, preserve that shape.
      ShapeMode.afterHeadline => state.shape,
      ShapeMode.other => Shape.other,
    };
  }
}

/// Different kinds of pending whitespace that have been requested.
///
/// Note that the order of values in the enum is significant: later ones have
/// more whitespace than previous ones.
enum Whitespace {
  /// No pending whitespace.
  none,

  /// A single space.
  space,

  /// A single newline.
  newline,

  /// Two newlines.
  blankLine;

  /// Combines two pending whitespaces and returns the result.
  ///
  /// When two whitespaces overlap, they aren't both written: we don't want
  /// two spaces or a newline followed by a space. Instead, the two whitespaces
  /// are collapsed such that the largest one wins.
  Whitespace collapse(Whitespace other) => values[max(index, other.index)];

  /// Whether this whitespace contains at least one newline.
  bool get hasNewline => switch (this) {
    newline || blankLine => true,
    _ => false,
  };
}

/// A kind of indentation that a [Piece] may output to control the leading
/// whitespace at the beginning of a line.
///
/// Each indentation type defines the number of spaces it writes. Indentation
/// is also semantic: a type describes *why* it writes that, or what kind of
/// syntax its coming from. This allows us to merge or combine indentation in
/// smarter ways in some contexts.
enum Indent {
  // No indentation.
  none(0),

  /// The right-hand side of an `=`, `:`, or `=>`.
  assignment(4),

  /// The contents of a block-like structure: block, collection literal,
  /// argument list, etc.
  block(2),

  /// A split cascade chain.
  cascade(2),

  /// Indentation when splits occur inside for-in and if-case clause headers.
  controlFlowClause(4),

  /// Any general sort of split expression.
  expression(4),

  /// "Indentation" for parenthesized expressions and other contexts where we
  /// want to prevent some inner expression's indentation from merging with
  /// the surrounding one.
  grouping(0),

  /// An infix operator expression: `+`, `*`, `is`, etc.
  infix(4),

  /// Constructor initializer when the parameter list doesn't have optional
  /// or named parameters.
  initializer(2),

  /// Constructor initializer when the parameter list does have optional or
  /// named parameters.
  initializerWithOptionalParameter(3);

  /// The number of spaces this type of indentation applies.
  final int spaces;

  const Indent(this.spaces);
}

/// Information for each piece currently being formatted while [CodeWriter]
/// traverses the piece tree.
class _FormatState {
  /// The piece being formatted.
  final Piece piece;

  /// The piece's shape.
  ///
  /// This changes based on the newlines the piece writes.
  Shape shape = Shape.inline;

  /// How a newline affects the shape of this piece.
  ShapeMode mode = ShapeMode.merge;

  _FormatState(this.piece);
}

/// Determines how a newline inside a piece or a child piece affects the shape
/// of the current piece.
enum ShapeMode {
  /// The piece's shape is merged with the incoming shape.
  ///
  /// If a newline is written directly by the piece itself, that has shape
  /// [Shape.other].
  merge,

  /// A newline makes this piece block-shaped.
  block,

  /// We are in the first line of a potentially headline-shaped piece.
  ///
  /// A newline here means it's not headline shaped.
  beforeHeadline,

  /// We've already written the headline part of a piece so a newline after
  /// this is fine and still leaves it headline shaped.
  afterHeadline,

  /// A newline makes this piece have [Shape.other].
  other,
}

/// A level of indentation in the indentation stack.
final class _IndentLevel {
  /// The reason this indentation was added.
  ///
  /// Not used for 3.7 style.
  final Indent type;

  /// The total number of spaces of indentation.
  final int spaces;

  /// How many spaces of [spaces] can be collapsed with further indentation.
  ///
  /// Only used for 3.7 style.
  final int collapsible;

  _IndentLevel.v37(this.spaces, this.collapsible) : type = Indent.none;

  _IndentLevel(this.type, this.spaces) : collapsible = 0;

  @override
  String toString() => '${type.name}:$spaces';
}
