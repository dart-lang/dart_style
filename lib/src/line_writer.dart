// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'dart_formatter.dart';
import 'debug.dart';
import 'line.dart';
import 'line_splitter.dart';

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

  /// `true` if this comment is a line comment.
  final bool isLineComment;

  SourceComment(this.text, this.linesBefore, {this.isLineComment});
}

class LineWriter {
  final DartFormatter _formatter;

  // TODO(bob): Private?
  final StringBuffer buffer;

  // TODO(bob): Make linked list for faster insert/remove.
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

  LineWriter(this._formatter, this.buffer) {
    increaseIndent(_formatter.indent);
  }

  /// Writes [string], the text for a single token, to the output.
  void write(String string) {
    _emitPendingWhitespace();
    _chunks.add(new TextChunk(string));

    // If we hadn't started a wrappable line yet, we have now, so start nesting.
    if (_nesting == -1) _nesting = 0;
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a soft split with [cost], [param] and unsplit [text].
  ///
  /// If [cost] is omitted, defaults to [SplitCost.FREE]. If [param] is omitted,
  /// one will be created. If a param is provided, [cost] is ignored. If
  /// omitted, [text] defaults to an empty string.
  void writeSplit({int cost, SplitParam param, String text}) {
    if (cost == null) cost = SplitCost.FREE;
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
  /// [linesAfterLast] is number of lines between the last comment (or previous
  /// token if there are no comments) and the next token.
  void writeComments(List<SourceComment> comments, int linesAfterLast,
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
      if (linesAfterLast > 1) {
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
            _chunks.last is SplitChunk &&
            _chunks.last.allowTrailingCommentBefore) {
          precedingSplit = _chunks.removeLast();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          write(" ");
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _addHardSplit(nest: true);
      }

      write(comment.text);

      if (precedingSplit != null) _chunks.add(precedingSplit);

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter = linesAfterLast;
      if (i < comments.length - 1) linesAfter = comments[i + 1].linesBefore;

      if (linesAfter > 0) _addHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.SPACE;
    }

    _preserveNewlines(linesAfterLast);
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

  void startSpan() {
    _spans.add(new SpanStartChunk());
    // TODO(bob): What about pending whitespace?
    _chunks.add(_spans.last);
  }

  void endSpan(int cost) {
    // TODO(bob): What about pending whitespace?
    _chunks.add(new SpanEndChunk(_spans.removeLast(), cost));
  }

  void startMultisplit({int cost: SplitCost.FREE, bool separable}) {
    _multisplits.add(new Multisplit(
        _chunks.length, cost, separable: separable));
  }

  /// Adds a new split point for the current innermost [Multisplit].
  ///
  /// If [text] is given, that will be the text of the unsplit chunk. If [nest]
  /// is `true`, then this split will take into account expression nesting.
  /// Otherwise, it will not. Collections do not follow expression nesting,
  /// while other uses of multisplits generally do.
  void multisplit({String text: "", bool nest: false,
      bool allowTrailingCommentBefore: true}) {
    _addSplit(new SplitChunk(_indent, nest ? _nesting : -1,
        param: _multisplits.last.param,
        text: text,
        allowTrailingCommentBefore: allowTrailingCommentBefore));
  }

  void endMultisplit() {
    var multisplit = _multisplits.removeLast();

    // See if it contains any hard splits that force it in turn to split.
    var forced = false;
    for (var i = multisplit.startChunk; i < _chunks.length; i++) {
      if (_chunks[i].isHardSplit) {
        forced = true;
        break;
      }
    }

    // TODO(bob): If last chunk is split for this multi, discard it? I think
    // that will completely eliminate the chunks for an empty block/collection.

    if (!forced) return;

    // Turn all of this multis soft splits into hard.
    for (var i = multisplit.startChunk; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (chunk.isSoftSplit && chunk.param == multisplit.param) chunk.harden();
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
    assert(_nesting == 0);

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
    if (debugFormatter) _dumpChunks("all chunks");

    // Break the chunks into unrelated lines that can be wrapped separately.
    var indent = _formatter.indent;
    var start = 0;
    var end;
    var pendingNewlines = 0;

    splitLine() {
      // TODO(bob): Lots of list copying. Linked list would be good here.
      var chunks = _chunks.getRange(start, end).toList();
      if (debugFormatter) _dumpChunks("top-level line", chunks);

      // Write newlines between each line.
      for (var i = 0; i < pendingNewlines; i++) {
        buffer.write(_formatter.lineEnding);
      }

      // Only write non-empty lines so we don't get trailing whitespace for
      // indentation.
      if (chunks.isNotEmpty) {
        var line = new Line(indent: indent);
        line.chunks.addAll(chunks);

        var splitter = new LineSplitter(_formatter.lineEnding,
            _formatter.pageWidth, line);

        splitter.apply(buffer);
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
        (chunk) => chunk is SplitChunk || chunk is TextChunk,
        orElse: () => null);

    // Don't need a space before a file-leading comment.
    if (chunk == null) return false;

    // Don't need a space if the comment isn't a trailing comment in the output.
    if (chunk is SplitChunk) return false;

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
  void _addHardSplit({bool nest: false, bool double: false}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;

    _addSplit(new SplitChunk(_indent, nest ? _nesting : -1, double: double));
  }

  /// Appends [split] to the output.
  void _addSplit(SplitChunk split) {
    // TODO(bob): What if pending is space?
    _emitPendingWhitespace();

    // Collapse duplicate splits.
    if (_chunks.isNotEmpty && _chunks.last is SplitChunk) {
      _chunks.last.mergeSplit(split);
    } else {
      _chunks.add(split);
    }
  }

  /*
  void _processIndents() {
    // Discard any indents that have no contents except for inline comments.
    for (var i = 0; i < _chunks.length - 1; i++) {
      // Find an indent.
      if (_chunks[i] is! IndentChunk) continue;

      // Look for an unindent "immediately" following it, where "immediately"
      // ignores inline comments.
      for (var j = i + 1; j < _chunks.length; j++) {
        var chunk = _chunks[j];

        // If we made it to the unindent without exiting the loop, it means
        // the indentation is not needed.
        if (chunk is UnindentChunk) {
          _chunks.removeAt(j);
          _chunks.removeAt(i);
          break;
        }

        // We can include comments that are completely inline, like:
        //
        //     main() {/* comment */ /* another */}
        if (chunk is CommentChunk && chunk.isTrailing && chunk.isLeading) {
          continue;
        }

        // Any other kind of chunk means the indented region is non-empty.
        break;
      }
    }

    // Corner case: comments on the same line as a token that begins
    // indentation but not on the same line as the end of the indentation
    // should get moved down to the next line.
    //
    //     main() { /* 1 */ // 2
    //     }
    //
    // becomes:
    //
    //     main() {
    //       /* 1 */ // 2
    //     }
    for (var i = 0; i < _chunks.length - 1; i++) {
      if (_chunks[i] is! IndentChunk) continue;
      if (_chunks[i + 1] is! CommentChunk) continue;

      // Skip over any fully inline comments.
      var j;
      for (j = i + 1; j < _chunks.length - 1; j++) {
        if (_chunks[j] is! CommentChunk || !_chunks[j].isInline) break;
      }

      if (j == _chunks.length) continue;

      // If those are followed by a trailing comment, then don't treat the
      // first comment like a trailing one. That will cause it to get moved to
      // the next line in a later pass.
      if (_chunks[j] is CommentChunk &&
          _chunks[j].isTrailing &&
          !_chunks[j].isLeading) {
        _chunks[i + 1].isTrailing = false;
      }
    }

    // Turn remaining indents into newlines.
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (chunk is! IndentChunk && chunk is! UnindentChunk) continue;

      // If the unindent doesn't require a newline, just delete it.
      if (chunk is UnindentChunk && !chunk.newline) {
        _chunks.removeAt(i--);
        continue;
      }

      // Indent chunks never occur in expression context, so ignore nesting.
      _chunks[i] = new WhitespaceChunk(Whitespace.NEWLINE, chunk.indent, -1);

      // If converting the [un]indent to a newline causes redundancy, discard
      // the earlier one.
      if (i > 0 && _chunks[i - 1] is WhitespaceChunk) {
        _chunks.removeAt(i - 1);
        i--;
      }
    }
  }

  /// Fixes places where a double newline before a comment is unneeded and not
  /// what the user authored.
  ///
  /// There are a few places in the style that require two newlines, for
  /// example, between top-level definitions. Sometimes a comment appears in
  /// the source *before* the required newlines. In that case, we don't need to
  /// also add two newlines before the comment. For example, given source like:
  ///
  ///     import 'a.dart';
  ///     // import 'b.dart';
  ///
  ///     class C {}
  ///
  /// This generates roughly chunks like:
  ///
  ///     Text "import 'a.dart';"
  ///     TwoNewlines                 // required double newline
  ///     Comment "import 'b.dart';"
  ///     TwoNewlines                 // the newlines authored after the comment
  ///     Text "class C {}"
  ///
  /// Since the later TwoNewlines provides the required separation, we can and
  /// want to turn the first one into a single newline to preserve the original
  /// correct structure.
  ///
  /// This does that. It looks for TwoNewlines that corresponded to a single
  /// newline in the source preceding a comment. When it finds one, it looks
  /// for another TwoNewlines after the comment. If found, it turns the first
  /// into a single newline.
  void _processCommentLines() {
    for (var i = 0; i < _chunks.length - 1; i++) {
      var chunk = _chunks[i];

      // Look for double newlines that were just a single newline in the source.
      if (chunk is WhitespaceChunk &&
          chunk.type == Whitespace.TWO_NEWLINES &&
          chunk.actual == 1 &&
          _chunks[i + 1] is CommentChunk) {

        // Look for another double newline in the subsequent chunks, ignoring
        // comments.
        for (var j = i + 1; j < _chunks.length; j++) {
          var next = _chunks[j];
          if (next is CommentChunk) {
            // Do nothing.
          } else if (next is WhitespaceChunk) {
            if (next.type == Whitespace.TWO_NEWLINES) {
              chunk.type = Whitespace.NEWLINE;
              i = j + 1;
              break;
            }
          } else {
            // If we hit anything else, we didn't find the double newline.
            break;
          }
        }
      }
    }
  }

  /// Massages whitespace surrounding comment chunks.
  void _processComments() {
    for (var i = 0; i < _chunks.length; i++) {
      if (_chunks[i] is CommentChunk) {
        i = _processComment(i);
      }
    }
  }

  int _processComment(int index) {
    var comment = _chunks[index] as CommentChunk;

    // TODO(bob): Probably need to do this in separate pass to handle sequential
    // comments. (Or just make CommentChunk extend TextChunk and leave alone).
    // Place the text of the comment.
    _chunks[index] = new TextChunk(comment.text);

    if (index > 0) {
      var before = _chunks[index - 1];

      if (before is WhitespaceChunk) {
        index = _processWhitespaceBeforeComment(before, comment, index);
      } else {
        if (comment.isBlockComment) {
          // TODO(bob): Need tests for multi-line block comments with and
          // without text following them, especially inside expressions where
          // nesting comes into play, like:
          //
          //     someMethod(argument, /*
          //     comment */ anotherArgument, ...);

          index = _processBeforeBlockComment(before, comment, index);
        } else {
          index = _processBeforeLineComment(before, comment, index);
        }
      }
    }

    // Add proper whitespace after it.
    if (comment.isBlockComment && _needsSpaceAfterBlockComment(index)) {
      _chunks.insert(++index, new SpaceChunk());
    }

    return index;
  }

  // TODO(bob): Doc.
  int _processBeforeBlockComment(
      Chunk before, CommentChunk comment, int index) {
    // Don't put spaces between grouping characters and block comments.
    if (before is TextChunk) {
      var needsSpace = true;

      // TODO(bob): Test.
      // Always put a space between line comments and other text.
      if (comment.isBlockComment) {
        if (before.text == "(" || before.text == "[" || before.text == "{") {
          needsSpace = false;
        }
      }

      if (needsSpace) {
        _chunks.insert(index++, new SpaceChunk());
      }

      return index;
    }

    // TODO(bob): Can delete this after sure all before cases handled.
    // The split takes care of any needed space.
    if (before is SoftSplitChunk) return index;
    if (before is SpaceChunk) return index;

    throw "TODO(bob): $before chunk before block comment not impl";
  }

  int _processBeforeLineComment(Chunk before, CommentChunk comment, int index) {
    // Don't split between a line comment and the text that precedes it.
    if (before is SoftSplitChunk) {
      // TODO(bob): Should not do this if source had newline before comment.
      // Replace the split with a space.
      _chunks[index - 1] = new SpaceChunk();
      return index;
    }

    if (before is TextChunk) {
      // Insert a space between the text and the comment.
      _chunks.insert(index++, new SpaceChunk());
      return index;
    }

    throw "TODO(bob): $before before line comment not impl";
  }

  int _processWhitespaceBeforeComment(WhitespaceChunk whitespace,
      CommentChunk comment, int index) {
    switch (whitespace.type) {
      case Whitespace.NEWLINE:
      case Whitespace.TWO_NEWLINES:
        // If the line comment is on the same line as the previous token,
        // push the whitespace after the comment and put a space before the
        // comment. Otherwise, leave the whitespace where it is so the comment
        // stays with the following token.
        if (comment.isTrailing) {
          _chunks[index - 1] = new SpaceChunk();

          // Move the existing newline after the comment with this one. If it's
          // a line comment, there is already one there, so we can replace that
          // one. Otherwise, we need to insert.
          if (comment.isBlockComment) _chunks.insert(index + 1, null);
          _chunks[index + 1] = whitespace;
        }
        break;

      default:
        throw "TODO(bob): ${whitespace.type} before comment not impl";
    }

    return index;
  }

  bool _needsSpaceAfterBlockComment(int index) {
    // Don't need a space after a trailing comment.
    if (index == _chunks.length - 1) return false;

    var after = _chunks[index + 1];

    if (after is TextChunk) {
      // Don't put spaces between grouping characters and block comments.
      if (after.text == ")" || after.text == "]" || after.text == "}" ||
          after.text == ",") {
        return false;
      }

      return true;
    }

    // TODO(bob): Is this correct in all cases?
    return false;
  }

  /// Goes through the line and turns any [WhitespaceChunk]s into more specific
  /// [HardSplitChunk]s.
  ///
  /// This must be called after [_processComments] since that will often create
  /// [WhitespaceChunk]s.
  void _processWhitespace() {
    // TODO(bob): Can this ever cause redundant newlines/splits/whitespace?
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (chunk is WhitespaceChunk) {
        switch (chunk.type) {
          case Whitespace.NEWLINE:
            _chunks[i] = new HardSplitChunk(chunk.indent, chunk.nesting);
            break;

          case Whitespace.TWO_NEWLINES:
            _chunks[i] = new HardSplitChunk(chunk.indent, chunk.nesting);
            _chunks.insert(++i,
                new HardSplitChunk(chunk.indent, chunk.nesting));
            break;

          default:
            throw "other whitespace ${chunk.type} not impl";
        }
      } else if (chunk is SpaceChunk) {
        _chunks[i] = new TextChunk(" ");
      }
    }

    // TODO(bob): Cleaner way of doing this?
    // Remove any trailing newlines.
    while (_chunks.last is HardSplitChunk) _chunks.removeLast();
  }
  */

  // TODO(bob): Need tests for line-splitting before and after block comments.

  void _dumpChunks(String label, [List<Chunk> chunks]) {
    if (chunks == null) chunks = _chunks;

    print("\n$label:");

    var i = 0;
    for (var chunk in chunks) {
      print("$i: $chunk");
      i++;
    }
  }
}

/*
/// The "middle" of the formatting pipeline for taking in text, newlines, and
/// chunks and emitting a series of logical (but unsplit) [Line]s.
///
/// This is written to by [SourceVisitor]. As each [Line] is completed, it gets
/// fed to a [LineSplitter], which ensures the resulting line stays with the
/// page boundary.
class LineWriter {
  final StringBuffer buffer;

  /// The current indentation level.
  ///
  /// Subsequent lines will be created with this much leading indentation.
  int _indent = 0;

  final DartFormatter _formatter;

  /// The whitespace that should be written before the next non-whitespace token
  /// or `null` if no whitespace is pending.
  Whitespace _pendingWhitespace;

  /// `true` if the next line should have its indentation cleared instead of
  /// using [indent].
  bool _clearNextIndent = false;

  /// The line currently being written to, or `null` if a non-empty line has
  /// not been started yet.
  Line _currentLine;

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

  /// The number of levels of expression nesting surrounding the chunks
  /// currently being written.
  int _expressionNesting = 0;

  LineWriter(this._formatter, this.buffer) {
    _indent = _formatter.indent;
  }

  /// Increase indentation by [n] levels.
  void indent([n = 1]) {
    _indent += n;
  }

  /// Decrease indentation by [n] levels.
  void unindent([n = 1]) {
    _indent -= n;
  }

  /// Forces the next line written to have no leading indentation.
  void clearIndentation() {
    _clearNextIndent = true;
  }

  /// Writes [string], the text for a single token, to the output.
  void write(String string) {
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.SPACE:
        if (_currentLine != null) _currentLine.write(" ");
        break;

      case Whitespace.NEWLINE:
        _newline();
        break;

      case Whitespace.TWO_NEWLINES:
        _newline();
        _newline();
        break;

      case Whitespace.SPACE_OR_NEWLINE:
      case Whitespace.ONE_OR_TWO_NEWLINES:
        // We should have pinned these down before getting here.
        assert(false);
    }

    _pendingWhitespace = null;

    _ensureLine();
    _currentLine.write(string);
  }

  /// Sets [whitespace] to be emitted before the next non-whitespace token.
  void writeWhitespace(Whitespace whitespace) {
    _pendingWhitespace = whitespace;
  }

  /// Updates the pending whitespace to a more precise amount given that the
  /// next token is [numLines] farther down from the previous token.
  void suggestWhitespace(int numLines) {
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

  void split({int cost, SplitParam param, String text}) {
    if (cost == null) cost = SplitCost.FREE;
    if (param == null) param = new SplitParam(cost);
    if (text == null) text = "";

    _writeSplit(new SplitChunk(param, _indent, _expressionNesting, text));
  }

  void startSpan() {
    _ensureLine();
    _spans.add(new SpanStartChunk());
    _currentLine.chunks.add(_spans.last);

    // Spans are used for argument lists which increase expression nesting for
    // indentation.
    nestExpression();
  }

  void endSpan(int cost) {
    _ensureLine();
    _currentLine.chunks.add(new SpanEndChunk(_spans.removeLast(), cost));

    // Spans are used for argument lists which increase expression nesting for
    // indentation.
    unnest();
  }

  void startMultisplit({int cost: SplitCost.FREE, bool separable}) {
    _multisplits.add(new Multisplit(cost, separable: separable));
  }

  /// Adds a new split point for the current innermost [Multisplit].
  ///
  /// If [text] is given, that will be the text of the unsplit chunk. If [nest]
  /// is `true`, then this split will take into account expression nesting.
  /// Otherwise, it will not. Collections do not follow expression nesting,
  /// while other uses of multisplits generally do.
  void multisplit({String text: "", bool nest: false}) {
    _writeSplit(new SplitChunk(_multisplits.last.param, _indent,
        nest ? _expressionNesting : -1, text));
  }

  void endMultisplit() {
    _multisplits.removeLast();
  }

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nestExpression() {
    _expressionNesting++;
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    _expressionNesting--;
  }

  /// Makes sure we have written one last trailing newline at the end of a
  /// compilation unit.
  void ensureNewline() {
    // If we already completed a line and haven't started a new one, there is
    // a trailing newline.
    if (_currentLine == null) return;

    _newline();
  }

  /// Finish writing the last line.
  void end() {
    if (_currentLine != null) _finishLine();
  }

  /// Prints the current line and completes it.
  ///
  /// If no tokens have been written since the last line was ended, this still
  /// prints an empty line.
  void _newline() {
    if (_currentLine == null) {
      buffer.write(_formatter.lineEnding);
      return;
    }

    // If we are in the middle of any all splits, they will definitely split
    // now.
    if (!_splitMultisplits()) {
      // The multisplits didn't leave a trailing newline, so add it now.
      _finishLine();
      buffer.write(_formatter.lineEnding);
    }

    _currentLine = null;
  }

  void _writeSplit(SplitChunk split) {
    // If this split is associated with a multisplit that's already been split,
    // treat it like a hard newline.
    var isSplit = false;
    for (var multisplit in _multisplits) {
      if (multisplit.isSplit && multisplit.param == split.param) {
        isSplit = true;
        break;
      }
    }

    if (isSplit) {
      // The line up to the split is complete now.
      if (_currentLine != null) {
        _finishLine();
        buffer.write(_formatter.lineEnding);
      }

      // Use the split's indent for the next line.
      _currentLine = new Line(indent: split.indent);
      return;
    }

    _ensureLine();
    _currentLine.chunks.add(split);
  }

  /// Lazily initializes [_currentLine] if not already created.
  void _ensureLine() {
    if (_currentLine != null) return;
    _currentLine = new Line(indent: _clearNextIndent ? 0 : _indent);
    _clearNextIndent = false;
  }

  /// Forces all multisplits in the current line to be split and breaks the
  /// line into multiple independent [Line] objects, each of which is printed
  /// separately (except for the last one, which is still in-progress).
  ///
  /// Returns `true` if the result of this left a trailing newline. This occurs
  /// when a multisplit chunk is the last chunk written before this is called.
  bool _splitMultisplits() {
    if (_multisplits.isEmpty) return false;

    var splitParams = new Set();
    for (var multisplit in _multisplits) {
      multisplit.split();
      if (multisplit.isSplit) splitParams.add(multisplit.param);
    }

    if (splitParams.isEmpty) return false;

    // Take any existing split points for the current multisplits and hard split
    // them into separate lines now that we know that those splits must apply.
    var chunks = _currentLine.chunks;
    _currentLine = new Line(indent: _currentLine.indent);
    var hasTrailingNewline = false;

    for (var chunk in chunks) {
      if (chunk is SplitChunk && splitParams.contains(chunk.param)) {
        var split = chunk as SplitChunk;
        _finishLine();
        buffer.write(_formatter.lineEnding);
        _currentLine = new Line(indent: split.indent);
        hasTrailingNewline = true;
      } else {
        _currentLine.chunks.add(chunk);
        hasTrailingNewline = false;
      }
    }

    return hasTrailingNewline;
  }

  void _finishLine() {
    // If the line has a trailing split, discard it since it will end up not
    // being split and becoming trailing whitespace. This can happen if a
    // comment appears immediately after a split.
    if (_currentLine.chunks.isNotEmpty &&
        _currentLine.chunks.last is SplitChunk) {
      _currentLine.chunks.removeLast();
    }

    var splitter = new LineSplitter(_formatter.lineEnding,
        _formatter.pageWidth, _currentLine);
    splitter.apply(buffer);
  }
}
*/