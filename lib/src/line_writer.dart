// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'dart_formatter.dart';
import 'chunk.dart';
import 'cost.dart';
import 'debug.dart';
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

  /// The whitespace that should be written to [_chunks] before the next
  ///  non-whitespace token or `null` if no whitespace is pending.
  ///
  /// This ensures that changes to indentation and nesting also apply to the
  /// most recent split, even if the visitor "creates" the split before changing
  /// indentation or nesting.
  Whitespace _pendingWhitespace;

  /// The number of newlines that need to be written to [_buffer] before the
  /// next line can be output.
  ///
  /// Where [_pendingWhitespace] buffers between the [SourceVisitor] and
  /// [_chunks], this buffers between the [LineWriter] and [_buffer]. It ensures
  /// we don't have trailing newlines in the output.
  int _bufferedNewlines = 0;

  /// The indentation at the beginning of the current complete line being
  /// written.
  int _beginningIndent;

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
  final _openSpans = <Span>[];

  /// All of the spans that have been created, open and closed.
  final _spans = <Span>[];

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

  /// The index of the "current" chunk being written.
  ///
  /// If the last chunk is still being appended to, this is its index.
  /// Otherwise, it is the index of the next chunk which will be created.
  int get _currentChunkIndex {
    if (_chunks.isEmpty) return 0;
    if (_chunks.last.canAddText) return _chunks.length - 1;
    return _chunks.length;
  }

  /// Whether there is pending whitespace that depends on the number of
  /// newlines in the source.
  ///
  /// This is used to avoid calculating the newlines between tokens unless
  /// actually needed since doing so is slow when done between every single
  /// token pair.
  bool get needsToPreserveNewlines =>
      _pendingWhitespace == Whitespace.ONE_OR_TWO_NEWLINES ||
      _pendingWhitespace == Whitespace.SPACE_OR_NEWLINE;

  LineWriter(this._formatter, this._buffer) {
    indent(_formatter.indent);
    _beginningIndent = _formatter.indent;
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// By default, this also implicitly adds one level of nesting if we aren't
  /// currently nested at all. We do this here so that if a comment appears
  /// after any token within a statement or top-level form and that comment
  /// leads to splitting, we correctly nest. Even pathological cases like:
  ///
  ///
  ///     import // comment
  ///         "this_gets_nested.dart";
  ///
  /// If we didn't do this here, we'd have to call [nestExpression] after the
  /// first token of practically every grammar production.
  void write(String string) {
    _emitPendingWhitespace();
    _writeText(string);

    // If we hadn't started a wrappable line yet, we have now, so start nesting.
    if (_nesting == -1) _nesting = 0;
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;

    // Any newline whitespace (coming from outside and not one created
    // internally in the writer by comments) implies that we're not nested
    // inside an expression, so clear any implicit nesting.
    if (type != Whitespace.SPACE) resetNesting();
  }

  /// Write a soft split with [cost] and [param].
  ///
  /// If unsplit, it expands to a space if [space] is `true`.
  ///
  /// If [cost] is omitted, defaults to [Cost.FREE]. If [param] is omitted, one
  /// will be created. If a param is provided, [cost] is ignored.
  void writeSplit({int cost, SplitParam param, bool space}) {
    if (cost == null) cost = Cost.CHEAP;
    if (param == null) param = new SplitParam(cost);

    _writeSplit(_indent, _nesting, param, spaceWhenUnsplit: space);

    // If a split inside a multisplit is chosen, this forces the multisplit too.
    // This ensures that, for example, a split inside a collection literal
    // forces the collection to also go multiline. Since a multisplit's param
    // also implies *its* surrounding multisplit, this will split the whole
    // chain of contained multisplits.
    if (_multisplits.isNotEmpty && _multisplits.last.param != null) {
      param.implies.add(_multisplits.last.param);
    }
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

      preserveNewlines(comment.linesBefore);

      // Don't emit a space because we'll handle it below. If we emit it here,
      // we may get a trailing space if the comment needs a line before it.
      if (_pendingWhitespace == Whitespace.SPACE) _pendingWhitespace = null;
      _emitPendingWhitespace();

      if (comment.linesBefore == 0) {
        // If we're sitting on a split, move the comment before it to adhere it
        // to the preceding text.
        if (_shouldMoveCommentBeforeSplit()) {
          _chunks.last.allowText();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          _writeText(" ");
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _writeHardSplit(nest: true, allowIndent: !comment.isStartOfLine,
            double: comment.linesBefore > 1);
      }

      _writeText(comment.text);

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter = linesBeforeToken;
      if (i < comments.length - 1) linesAfter = comments[i + 1].linesBefore;

      if (linesAfter > 0) _writeHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.SPACE;
    }

    preserveNewlines(linesBeforeToken);
  }

  /// If the current pending whitespace allows some source discretion, pins
  /// that down given that the source contains [numLines] newlines at that
  /// point.
  void preserveNewlines(int numLines) {
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

  /// Increases indentation of the next line by [levels].
  void indent([int levels = 1]) {
    while (levels-- > 0) _indentStack.add(-1);
  }

  /// Decreases indentation of the next line by [levels].
  void unindent([int levels = 1]) {
    while (levels-- > 0) _indentStack.removeLast();
  }

  /// Starts a new span with [cost].
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan([int cost = Cost.CHEAP]) {
    _openSpans.add(new Span(_currentChunkIndex, cost));
  }

  /// Ends the innermost span.
  void endSpan() {
    var span = _openSpans.removeLast();
    span.close(_currentChunkIndex);

    // A span that just covers a single chunk can't be split anyway.
    if (span.start == span.end) return;
    _spans.add(span);
  }

  /// Starts a new [Multisplit] with [cost].
  void startMultisplit({int cost: Cost.CHEAP, bool separable}) {
    var multisplit = new Multisplit(
        _currentChunkIndex, cost, separable: separable);

    _multisplits.add(multisplit);
  }

  /// Adds a new split point for the current innermost [Multisplit].
  ///
  /// If [space] is `true`, the chunk will include a space when unsplit. If
  /// [nest] is `true`, then this split will take into account expression
  /// nesting. Otherwise, it will not. Collections do not follow expression
  /// nesting, while other uses of multisplits generally do.
  void multisplit({bool nest: false, bool space}) {
    _writeSplit(_indent, nest ? _nesting : -1, _multisplits.last.param,
        spaceWhenUnsplit: space);
  }

  /// Ends the innermost multisplit.
  void endMultisplit() {
    var multisplit = _multisplits.removeLast();

    // If this multisplit is contained in another one and they didn't already
    // get hardened, wire them together: if the inner one chooses to split, it
    // should force the outer one to split too.
    if (_multisplits.isNotEmpty &&
        multisplit.param != null &&
        _multisplits.last.param != null) {
      multisplit.param.implies.add(_multisplits.last.param);
    }
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
    if (_chunks.isNotEmpty) _completeLine();
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
        _writeText(" ");
        break;

      case Whitespace.NEWLINE:
        _writeHardSplit();
        break;

      case Whitespace.TWO_NEWLINES:
        _writeHardSplit(double: true);
        break;

      case Whitespace.SPACE_OR_NEWLINE:
      case Whitespace.ONE_OR_TWO_NEWLINES:
        // We should have pinned these down before getting here.
        assert(false);
        break;
    }

    _pendingWhitespace = null;
  }

  /// Returns `true` if the last chunk is a split that should be move after the
  /// comment that is about to be written.
  bool _shouldMoveCommentBeforeSplit() {
    // Not if there is nothing before it.
    if (_chunks.isEmpty) return false;

    // If the text before the split is an open grouping character, we don't
    // want to adhere the comment to that.
    var text = _chunks.last.text;
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
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
    // Not at the start of the file.
    if (_chunks.isEmpty) return false;

    // Not at the start of a line.
    if (!_chunks.last.canAddText) return false;

    var text = _chunks.last.text;
    if (text.endsWith("\n")) return false;

    // Always put a space before line comments.
    if (isLineComment) return true;

    // Block comments do not get a space if following a grouping character.
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the token that will be written.
  bool _needsSpaceAfterLastComment(List<SourceComment> comments, String token) {
    // Not if there are no comments.
    if (comments.isEmpty) return false;

    // Not at the beginning of a line.
    if (!_chunks.last.canAddText) return false;

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
  void _writeHardSplit({bool nest: false, bool double: false,
      bool allowIndent: true}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;

    var indent = _indent;
    var nesting = nest ? _nesting : -1;
    if (!allowIndent) {
      indent = 0;
      nesting = -1;
    }

    _writeSplit(indent, nesting, null, isDouble: double);
  }

  /// Ends the current chunk (if any) with the given split information.
  void _writeSplit(int indent, int nesting, SplitParam param,
      {bool isDouble, bool spaceWhenUnsplit}) {
    if (_chunks.isEmpty) return;

    _chunks.last.applySplit(indent, nesting, param,
        isDouble: isDouble, spaceWhenUnsplit: spaceWhenUnsplit);

    if (_chunks.last.isHardSplit) _splitMultisplits();
  }

  /// Writes [text] to either the current chunk or a new one if the current
  /// chunk is complete.
  void _writeText(String text) {
    if (_chunks.isEmpty) {
      _chunks.add(new Chunk(text));
    } else if (_chunks.last.canAddText) {
      _chunks.last.appendText(text);
    } else {
      // Since we're about to write some text on the next line, we know the
      // previous one is fully done being tweaked and merged, so now we can see
      // if it can be split independently.
       _checkForCompleteLine();

      _chunks.add(new Chunk(text));
    }
  }

  /// Checks to see if we are currently at a point where the existing chunks
  /// can be processed as a single line and processes them if so.
  ///
  /// We want to send small lists of chunks to [LineSplitter] for performance.
  /// We can do that when we know one set of chunks will absolutely not affect
  /// anything following it. The rule for that is pretty simple: a hard newline
  /// that is not nested inside an expression.
  void _checkForCompleteLine() {
    if (_chunks.isEmpty) return;

    // Can only split on a hard line that is not nested in the middle of an
    // expression.
    if (!_chunks.last.isHardSplit || _chunks.last.nesting >= 0) return;

    // If we're still in the middle of a span, wait until it's done so we can
    // calculate costs correctly.
    if (_openSpans.isNotEmpty) return;

    // Hang on to the split info so we can reset the writer to start with it.
    var split = _chunks.last;

    // Don't write any empty line, just discard it.
    if (_chunks.isNotEmpty) {
      _completeLine();
      _chunks.clear();
    }

    _spans.clear();

    // Get ready for the next line.
    _bufferedNewlines = split.isDouble ? 2 : 1;
    _beginningIndent = split.indent;
  }

  /// Hands off the current list of chunks to [LineSplitter] as a single logical
  /// line.
  void _completeLine() {
    assert(_chunks.isNotEmpty);

    if (debugFormatter) dumpChunks(_chunks);

    // Write the newlines required by the previous line.
    for (var i = 0; i < _bufferedNewlines; i++) {
      _buffer.write(_formatter.lineEnding);
    }

    var splitter = new LineSplitter(_formatter.lineEnding,
        _formatter.pageWidth, _chunks, _spans, _beginningIndent);
    splitter.apply(_buffer);
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

    // Add [param] and the transitive closure of its implied params to
    // [splitParams].
    traverseParams(param) {
      splitParams.add(param);

      // Traverse the tree of implied params.
      param.implies.forEach(traverseParams);
    }

    for (var multisplit in _multisplits) {
      // If this multisplit isn't separable or already split, we need to harden
      // all of its previous splits now.
      var param = multisplit.harden();
      if (param != null) traverseParams(param);
    }

    if (splitParams.isEmpty) return;

    // Take any existing splits for the multisplits and hard split them.
    for (var chunk in _chunks) {
      if (chunk.param == null) continue;

      if (splitParams.contains(chunk.param)) {
        chunk.harden();
      } else {
        // If the chunk isn't hardened, but implies something that is, we can
        // discard the implication since it is always satisfied now.
        chunk.param.implies.removeWhere(splitParams.contains);
      }
    }
  }
}
