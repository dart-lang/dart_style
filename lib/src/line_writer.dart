// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'dart_formatter.dart';
import 'debug.dart';
import 'chunk.dart';
import 'cost.dart';
import 'line_splitter.dart';
import 'multisplit.dart';
import 'whitespace.dart';

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
class SourceComment {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  final String text;

  /// The number of newlines between the comment or token preceding this comment
  /// and the beginning of this one.
  ///
  /// Will be zero if the comment is a trailing one.
  final int linesBefore;

  /// Whether this comment is a line comment.
  final bool isLineComment;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool isStartOfLine;

  SourceComment(this.text, this.linesBefore,
      {this.isLineComment, this.isStartOfLine});
}

/// Takes the incremental serialized output of [SourceVisitor]--the source text
/// along with any comments and preserved whitespace--and produces a coherent
/// series of [Chunk]s which can then be split into physical lines.
///
/// Keeps track of leading indentation, expression nesting, and all of the hairy
/// code required to seamlessly integrate existing comments into the pure
/// output produced by [SourceVisitor].
class LineWriter {
  final DartFormatter _formatter;

  final StringBuffer _buffer;

  final _chunks = <Chunk>[];

  /// The whitespace that should be written before the next non-whitespace token
  /// or `null` if no whitespace is pending.
  Whitespace _pendingWhitespace;

  /// The nested stack of multisplits that are currently being written.
  ///
  /// If a hard newline appears in the middle of a multisplit, then the
  /// multisplit itself must be split. For example, a collection can either be
  /// single line:
  ///
  ///    [all, on, one, line];
  ///
  /// or multi-line:
  ///
  ///    [
  ///      one,
  ///      item,
  ///      per,
  ///      line
  ///    ]
  ///
  /// Collections can also contain function expressions, which have blocks which
  /// in turn force a newline in the middle of the collection. When that
  /// happens, we need to force all surrounding collections to be multi-line.
  /// This tracks them so we can do that.
  final _multisplits = <Multisplit>[];

  /// The nested stack of spans that are currently being written.
  final _spans = <SpanStartChunk>[];

  /// The current indentation and nesting levels.
  ///
  /// This is tracked as a stack of numbers. Each element in the stack
  /// represents a level of statement indentation. The number of the element is
  /// the current expression nesting depth for that statement.
  ///
  /// It's stored as a stack because expressions may contain statements which
  /// in turn contain other expressions. The nesting level of the inner
  /// expressions are unrelated to the surrounding ones. For example:
  ///
  ///     outer(invocation(() {
  ///       inner(lambda());
  ///     }));
  ///
  /// When writing `inner(lambda())`, we need to track its nesting level. At
  /// the same time, when the lambda is done, we need to return to the nesting
  /// level of `outer(invocation(...`.
  ///
  /// Start with an implicit entry so that top-level definitions and directives
  /// can be split.
  var _indentStack = [-1];

  /// The current indentation, not including expression nesting.
  int get _indent => _indentStack.length - 1;

  /// The nesting depth of the current inner-most block.
  int get _nesting => _indentStack.last;
  void set _nesting(int value) {
    _indentStack[_indentStack.length - 1] = value;
  }

  LineWriter(this._formatter, this._buffer) {
    increaseIndent(_formatter.indent);
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// By default, this will also implicitly add one level of nesting if we
  /// aren't currently nested at all. We do this here so that if a comment
  /// appears after any token within a statement or top-level form and that
  /// comment leads to splitting, we correctly nest. Even pathological cases
  /// like:
  ///
  ///     import // comment
  ///         "this_gets_nested.dart";
  ///
  /// If we didn't do this here, we'd have to call [nestExpression] after the
  /// first token of practically every grammar production.
  ///
  /// However, comments are also written by calling this. Those *don't*
  /// increase nesting, otherwise you'd end up with:
  ///
  ///     main() {
  ///       // first
  ///           code();
  ///     }
  ///
  /// They pass `false` for [implyNesting] to avoid that.
  void write(String string, {bool implyNesting: true}) {
    _emitPendingWhitespace();
    _chunks.add(new TextChunk(string));

    // If we hadn't started a wrappable line yet, we have now, so start nesting.
    if (implyNesting && _nesting == -1) _nesting = 0;
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a soft split with [cost], [param] and unsplit [text].
  ///
  /// If [cost] is omitted, defaults to [Cost.FREE]. If [param] is omitted, one
  /// will be created. If a param is provided, [cost] is ignored. If omitted,
  /// [text] defaults to an empty string.
  void writeSplit({int cost, SplitParam param, String text}) {
    if (cost == null) cost = Cost.FREE;
    if (param == null) param = new SplitParam(cost);
    if (text == null) text = "";

    _addSplit(new SplitChunk(_indent, _nesting, param: param, text: text));
  }

  /// Outputs the series of [comments] and associated whitespace that appear
  /// before [token] (which is not written by this).
  ///
  /// The list contains each comment as it appeared in the source between the
  /// last token written and the next one that's about to be written.
  ///
  /// [linesBeforeToken] is number of lines between the last comment (or
  /// previous token if there are no comments) and the next token.
  void writeComments(List<SourceComment> comments, int linesBeforeToken,
      String token) {
    // Corner case: if we require a blank line, but there exists one between
    // some of the comments, or after the last one, then we don't need to
    // enforce one before the first comment. Example:
    //
    //     library foo;
    //     // comment
    //
    //     class Bar {}
    //
    // Normally, a blank line is required after `library`, but since there is
    // one after the comment, we don't need one before it. This is mainly so
    // that commented out directives stick with their preceding group.
    if (_pendingWhitespace == Whitespace.TWO_NEWLINES &&
        comments.isNotEmpty &&
        comments.first.linesBefore < 2) {
      if (linesBeforeToken > 1) {
        _pendingWhitespace = Whitespace.NEWLINE;
      } else {
        for (var i = 1; i < comments.length; i++) {
          if (comments[i].linesBefore > 1) {
            _pendingWhitespace = Whitespace.NEWLINE;
            break;
          }
        }
      }
    }

    // Write each comment and the whitespace between them.
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      _preserveNewlines(comment.linesBefore);
      _emitPendingWhitespace();

      var precedingSplit;

      if (comment.linesBefore == 0) {
        // If we're sitting on a split, move the comment before it to adhere it
        // to the preceding text.
        if (_chunks.isNotEmpty &&
            _chunks.last.isSplit &&
            _chunks.last.allowTrailingCommentBefore) {
          precedingSplit = _chunks.removeLast();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          write(" ", implyNesting: false);
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _addHardSplit(nest: true, allowIndent: !comment.isStartOfLine);
      }

      write(comment.text, implyNesting: false);

      if (precedingSplit != null) _chunks.add(precedingSplit);

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter = linesBeforeToken;
      if (i < comments.length - 1) linesAfter = comments[i + 1].linesBefore;

      if (linesAfter > 0) _addHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.SPACE;
    }

    _preserveNewlines(linesBeforeToken);
  }

  // TODO(bob): Lose these and just do explicit newlines()?
  /// Outputs an [IndentChunk] that emits a newline and increases indentation by
  /// [levels].
  void indent({int levels: 1}) {
    increaseIndent(levels);
    _addHardSplit();
  }

  /// Outputs [UnindentChunk] that decreases indentation by [levels].
  ///
  /// If [newline] is `false`, does not add a newline. Otherwise, it does.
  void unindent({int levels: 1, bool newline: true}) {
    decreaseIndent(levels);
    if (newline) _addHardSplit();
  }

  /// Increase indentation of the next line by [levels].
  ///
  /// Unlike [indent], this does not insert an [IndentChunk] or a newline. It's
  /// used to explicitly control indentation within an expression or statement,
  /// for example, indenting subsequent variables in a variable declaration.
  void increaseIndent([int levels = 1]) {
    while (levels-- > 0) _indentStack.add(-1);
  }

  /// Decreases indentation of the next line by [levels].
  ///
  /// Unlike [unindent], this does not insert an [UnindentChunk] or a newline.
  /// It's used to explicitly control indentation within an expression or
  /// statement, for example, indenting subsequent variables in a variable
  /// declaration.
  void decreaseIndent([int levels = 1]) {
    while (levels-- > 0) _indentStack.removeLast();
  }

  /// Starts a new span.
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan() {
    _spans.add(new SpanStartChunk());
    _chunks.add(_spans.last);
  }

  /// Ends the innermost span and associates [cost] with it.
  void endSpan(int cost) {
    _chunks.add(new SpanEndChunk(_spans.removeLast(), cost));
  }

  /// Starts a new [Multisplit] with [cost].
  void startMultisplit({int cost: Cost.FREE, bool separable}) {
    _multisplits.add(new Multisplit(
        _chunks.length, cost, separable: separable));
  }

  /// Adds a new split point for the current innermost [Multisplit].
  ///
  /// If [text] is given, that will be the text of the unsplit chunk. If [nest]
  /// is `true`, then this split will take into account expression nesting.
  /// Otherwise, it will not. Collections do not follow expression nesting,
  /// while other uses of multisplits generally do.
  ///
  /// If [allowTrailingCommentBefore] is `false`, then a comment is not allowed
  /// to adhere to the previous token and remain on the line before the split.
  void multisplit({String text: "", bool nest: false,
      bool allowTrailingCommentBefore: true}) {
    _addSplit(new SplitChunk(_indent, nest ? _nesting : -1,
        param: _multisplits.last.param,
        text: text,
        allowTrailingCommentBefore: allowTrailingCommentBefore));
  }

  /// Ends the innermost multisplit.
  void endMultisplit() {
    _multisplits.removeLast();
  }

  /// Resets the expression nesting back to the "top-level" unnested state.
  ///
  /// One level of nesting is implicitly created after the first piece of text
  /// written to a line. This is done automatically so we don't have to add tons
  /// of [nestExpression] calls throughout the visitor.
  ///
  /// Once we reach the end of a wrappable "line" (a statement, top-level
  /// variable, directive, etc.), this implicit nesting needs to be discarded.
  ///
  void resetNesting() {
    // All other explicit nesting should have been discarded by now.
    assert(_nesting <= 0);

    // TODO(bob): Call this after directives, and top-level
    // definitions.

    _nesting = -1;
  }

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nestExpression() {
    _nesting++;
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    _nesting--;
  }

  /// Finish writing the last line.
  void end() {
    // Discard any trailing splits.
    while (_chunks.isNotEmpty && _chunks.last.isSplit) {
      _chunks.removeLast();
    }

    if (debugFormatter) dumpChunks(_chunks);

    // Break the chunks into unrelated lines that can be wrapped separately.
    var indent = _formatter.indent;
    var start = 0;
    var end;
    var pendingNewlines = 0;

    splitLine() {
      // TODO(bob): Lots of list copying. Linked list would be good here.
      var chunks = _chunks.getRange(start, end).toList();

      // Write newlines between each line.
      for (var i = 0; i < pendingNewlines; i++) {
        _buffer.write(_formatter.lineEnding);
      }

      // Only write non-empty lines so we don't get trailing whitespace for
      // indentation.
      if (chunks.isNotEmpty) {
        var splitter = new LineSplitter(_formatter.lineEnding,
            _formatter.pageWidth, chunks, indent);
        splitter.apply(_buffer);
      }

      start = end + 1;
    }

    for (end = 0; end < _chunks.length; end++) {
      var chunk = _chunks[end];

      // TODO(bob): Do this while chunks are being written instead of all at
      // the end.
      if (chunk.isHardSplit && chunk.indent == 0 && chunk.nesting == 0) {
        splitLine();
        indent = _chunks[end].indent;
        pendingNewlines = chunk.isDouble ? 2 : 1;
      }
    }

    // Handle the last line.
    if (start < end) splitLine();
  }

  /// If the current pending whitespace allows some source discretion, pins
  /// that down given that the source contains [numLines] newlines at that
  /// point.
  void _preserveNewlines(int numLines) {
    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pendingWhitespace) {
      case Whitespace.SPACE_OR_NEWLINE:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.NEWLINE;
        } else {
          _pendingWhitespace = Whitespace.SPACE;
        }
        break;

      case Whitespace.ONE_OR_TWO_NEWLINES:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.TWO_NEWLINES;
        } else {
          _pendingWhitespace = Whitespace.NEWLINE;
        }
        break;
    }
  }

  /// Writes the current pending [Whitespace] to the output, if any.
  ///
  /// This should only be called after source lines have been preserved to turn
  /// any ambiguous whitespace into a concrete choice.
  void _emitPendingWhitespace() {
    if (_pendingWhitespace == null) return;
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.SPACE:
        _chunks.add(new TextChunk(" "));
        break;

      case Whitespace.NEWLINE:
        _addHardSplit();
        break;

      case Whitespace.TWO_NEWLINES:
        _addHardSplit(double: true);
        break;

      case Whitespace.SPACE_OR_NEWLINE:
      case Whitespace.ONE_OR_TWO_NEWLINES:
        // We should have pinned these down before getting here.
        assert(false);
        break;
    }

    _pendingWhitespace = null;
  }

  /// Returns `true` if a space should be output between the end of the current
  /// output and the subsequent comment which is about to be written.
  ///
  /// This is only called if the comment is trailing text in the unformatted
  /// source. In most cases, a space will be output to separate the comment
  /// from what precedes it. This returns false if:
  ///
  /// *   This comment does begin the line in the output even if it didn't in
  ///     the source.
  /// *   The comment is a block comment immediately following a grouping
  ///     character (`(`, `[`, or `{`). This is to allow `foo(/* comment */)`,
  ///     et. al.
  bool _needsSpaceBeforeComment({bool isLineComment}) {
    // Find the preceding visible (non-span) chunk, if any.
    var chunk = _chunks.lastWhere(
        (chunk) => chunk.isSplit || chunk is TextChunk,
        orElse: () => null);

    // Don't need a space before a file-leading comment.
    if (chunk == null) return false;

    // Don't need a space if the comment isn't a trailing comment in the output.
    if (chunk.isSplit) return false;

    assert(chunk is TextChunk);
    var text = (chunk as TextChunk).text;

    // Don't add a space if there already is one.
    if (text == " ") return false;

    // Always put a space before line comments.
    if (isLineComment) return true;

    // Block comments do not get a space if following a grouping character.
    return text != "(" && text != "[" && text != "{";
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the token that will be written.
  bool _needsSpaceAfterLastComment(List<SourceComment> comments, String token) {
    // If there are no comments (except the sentinel fake one), don't need a
    // space.
    if (comments.isEmpty) return false;

    // If there is a split after the last comment, we don't need a space.
    if (_chunks.last is! TextChunk) return false;

    // Otherwise, it gets a space if the following token is not a grouping
    // character, a comma, (or the empty string, for EOF).
    return token != ")" && token != "]" && token != "}" &&
        token != "," && token != "";
  }

  /// Appends a hard split with the current indentation and nesting (the latter
  /// only if [nest] is `true`).
  ///
  /// If [double] is `true`, a double-split (i.e. a blank line) is output.
  ///
  /// If [allowIndent] is `false, then the split will always cause the next
  /// line to be at column zero. Otherwise, it uses the normal indentation and
  /// nesting behavior.
  void _addHardSplit({bool nest: false, bool double: false,
      bool allowIndent: true}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;

    var indent = _indent;
    var nesting = nest ? _nesting : -1;
    if (!allowIndent) {
      indent = 0;
      nesting = -1;
    }

    _addSplit(new SplitChunk(indent, nesting, double: double));
  }

  /// Appends [split] to the output.
  void _addSplit(SplitChunk split) {
    // Don't allow leading newlines.
    if (_chunks.isEmpty) return;

    // TODO(bob): What if pending is space?
    _emitPendingWhitespace();

    // Collapse duplicate splits.
    if (_chunks.isNotEmpty && _chunks.last.isSplit) {
      _chunks.last.mergeSplit(split);
    } else {
      _chunks.add(split);
    }

    if (_chunks.last.isHardSplit) _splitMultisplits();
  }

  /// Handles multisplits when a hard line occurs.
  ///
  /// Any active separable multisplits will get split in two at this point.
  /// Other multisplits are forced into the "hard" state. All of their previous
  /// splits are turned into explicit hard splits and any new splits for that
  /// multisplit become hard splits too.
  void _splitMultisplits() {
    if (_multisplits.isEmpty) return;

    var splitParams = new Set();
    for (var multisplit in _multisplits) {
      // If this multisplit isn't separable or already split, we need to harden
      // all of its previous splits now.
      var param = multisplit.harden();
      if (param != null) splitParams.add(param);
    }

    if (splitParams.isEmpty) return;

    // Take any existing splits for the multisplits and hard split them.
    for (var chunk in _chunks) {
      if (chunk.isSoftSplit && chunk.shouldSplit(splitParams)) {
        chunk.harden();
      }
    }
  }

  // TODO(bob): Need tests for line-splitting before and after block comments.
}
