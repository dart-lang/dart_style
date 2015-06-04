// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'chunk.dart';
import 'dart_formatter.dart';
import 'debug.dart' as debug;
import 'indent_stack.dart';
import 'line_splitter.dart';
import 'rule.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// Takes the incremental serialized output of [SourceVisitor]--the source text
/// along with any comments and preserved whitespace--and produces a coherent
/// series of [Chunk]s which can then be split into physical lines.
///
/// Keeps track of leading indentation, expression nesting, and all of the hairy
/// code required to seamlessly integrate existing comments into the pure
/// output produced by [SourceVisitor].
class LineWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  final _buffer = new StringBuffer();

  final _chunks = <Chunk>[];

  /// The whitespace that should be written to [_chunks] before the next
  ///  non-whitespace token or `null` if no whitespace is pending.
  ///
  /// This ensures that changes to indentation and nesting also apply to the
  /// most recent split, even if the visitor "creates" the split before changing
  /// indentation or nesting.
  Whitespace _pendingWhitespace;

  /// The nested stack of rules that are currently in use.
  ///
  /// New chunks are implicitly split by the innermost rule when the chunk is
  /// ended.
  final _rules = <Rule>[];

  /// The list of rules that are waiting until the next whitespace has been
  /// written before they start.
  final _lazyRules = <Rule>[];

  /// The chunks owned by each rule (except for hard splits).
  final _ruleChunks = <Rule, List<Chunk>>{};

  /// The nested stack of spans that are currently being written.
  final _openSpans = <OpenSpan>[];

  /// The current indentation levels.
  final _stack = new IndentStack();

  /// The index of the "current" chunk being written.
  ///
  /// If the last chunk is still being appended to, this is its index.
  /// Otherwise, it is the index of the next chunk which will be created.
  int get _currentChunkIndex {
    if (_chunks.isEmpty) return 0;
    if (_chunks.last.canAddText) return _chunks.length - 1;
    return _chunks.length;
  }

  /// The offset in [_buffer] where the selection starts in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the beginning of the selection yet.
  int _selectionStart;

  /// The length in [_buffer] of the selection in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the end of the selection yet.
  int _selectionLength;

  /// Whether there is pending whitespace that depends on the number of
  /// newlines in the source.
  ///
  /// This is used to avoid calculating the newlines between tokens unless
  /// actually needed since doing so is slow when done between every single
  /// token pair.
  bool get needsToPreserveNewlines =>
      _pendingWhitespace == Whitespace.oneOrTwoNewlines ||
      _pendingWhitespace == Whitespace.spaceOrNewline;

  /// The number of characters of code that can fit in a single line.
  int get pageWidth => _formatter.pageWidth;

  /// The current innermost rule.
  Rule get rule => _rules.last;

  LineWriter(this._formatter, this._source) {
    indent(_formatter.indent);
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

    _lazyRules.forEach(startRule);
    _lazyRules.clear();

    _stack.commitNesting();
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a split owned by the current innermost rule.
  ///
  /// Ignores nesting when split if [nest] is `false`. If unsplit, it expands
  /// to a space if [space] is `true`.
  Chunk split({bool nest: true, bool space}) =>
      _writeSplit(_rules.last, nest: nest, spaceWhenUnsplit: space);

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
    if (_pendingWhitespace == Whitespace.twoNewlines &&
        comments.isNotEmpty &&
        comments.first.linesBefore < 2) {
      if (linesBeforeToken > 1) {
        _pendingWhitespace = Whitespace.newline;
      } else {
        for (var i = 1; i < comments.length; i++) {
          if (comments[i].linesBefore > 1) {
            _pendingWhitespace = Whitespace.newline;
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
      if (_pendingWhitespace == Whitespace.space) _pendingWhitespace = null;
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
        _writeHardSplit(nest: true, flushLeft: comment.isStartOfLine,
            double: comment.linesBefore > 1);
      }

      _writeText(comment.text);

      if (comment.selectionStart != null) {
        startSelectionFromEnd(comment.text.length - comment.selectionStart);
      }

      if (comment.selectionEnd != null) {
        endSelectionFromEnd(comment.text.length - comment.selectionEnd);
      }

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter;
      if (i < comments.length - 1) {
        linesAfter = comments[i + 1].linesBefore;
      } else {
        linesAfter = linesBeforeToken;

        // Always force a newline after multi-line block comments. Prevents
        // mistakes like:
        //
        //     /**
        //      * Some doc comment.
        //      */ someFunction() { ... }
        if (linesAfter == 0 && comments.last.text.contains("\n")) {
          linesAfter = 1;
        }
      }

      if (linesAfter > 0) _writeHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.space;
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
      case Whitespace.spaceOrNewline:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.nestedNewline;
        } else {
          _pendingWhitespace = Whitespace.space;
        }
        break;

      case Whitespace.oneOrTwoNewlines:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.twoNewlines;
        } else {
          _pendingWhitespace = Whitespace.newline;
        }
        break;
    }
  }

  /// Increases indentation of the next line by [levels].
  void indent([int levels = 1]) {
    _stack.indent(levels);
  }

  /// Decreases indentation of the next line by [levels].
  void unindent([int levels = 1]) {
    _stack.unindent(levels);
  }

  /// Begins a new body.
  ///
  /// Used for function expressions and collection literals. Unlike simple
  /// indentation, the entire contents of a body may be indented based on
  /// the nesting of the expression containing the body. For example:
  ///
  ///     function(
  ///         {
  ///           innerFunction;
  ///         },
  ///         [
  ///           list,
  ///           elements
  ///         ],
  ///         argument);
  ///
  /// Note that the function and list bodies are both indented +4 to match the
  /// argument lists's indentation.
  void startBody() {
    _stack.startBody();
  }

  /// Ends the innermost body.
  void endBody() {
    _stack.endBody();
  }

  /// Starts a new span with [cost].
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan([int cost = Cost.normal]) {
    _openSpans.add(new OpenSpan(_currentChunkIndex, cost));
  }

  /// Ends the innermost span.
  void endSpan() {
    var openSpan = _openSpans.removeLast();

    // If the span was discarded while it was still open, just forget about it.
    if (openSpan == null) return;

    // A span that just covers a single chunk can't be split anyway.
    var end = _currentChunkIndex;
    if (openSpan.start == end) return;

    // Add the span to every chunk that can split it.
    var span = new Span(openSpan.cost);
    for (var i = openSpan.start; i < end; i++) {
      var chunk = _chunks[i];
      if (!chunk.isHardSplit) chunk.spans.add(span);
    }
  }

  /// Starts a new [Rule].
  ///
  /// If omitted, defaults to a new [SimpleRule].
  void startRule([Rule rule]) {
    //assert(_pendingRule == null);

    if (rule == null) rule = new SimpleRule();

    // See if any of the rules that contain this one care if it splits.
    _rules.forEach((outer) => outer.contain(rule));
    _rules.add(rule);

    // Keep track of the rule's chunk range so we know how to calculate its
    // length for preemption.
    rule.start = _currentChunkIndex;
  }

  /// Starts a new [Rule] that comes into play *after* the next whitespace
  /// (including comments) is written.
  ///
  /// This is used for binary operators who want to start a rule before the
  /// first operand but not get forced to split if a comment appears before the
  /// entire expression.
  ///
  /// If [rule] is omitted, defaults to a new [SimpleRule].
  void startLazyRule([Rule rule]) {
    if (rule == null) rule = new SimpleRule();

    _lazyRules.add(rule);
  }

  /// Ends the innermost rule.
  void endRule() {
    // Keep track of the rule's chunk range so we know how to calculate its
    // length for preemption.
    _rules.removeLast().end = _currentChunkIndex;
  }

  /// Pre-emptively forces all of the current rules to become hard splits.
  ///
  /// This is called by [SourceVisitor] when it can determine that a rule will
  /// will always be split. Turning it (and the surrounding rules) into hard
  /// splits lets the writer break the output into smaller pieces for the line
  /// splitter, which helps performance and avoids failing on very large input.
  ///
  /// In particular, it's easy for the visitor to know that collections with a
  /// large number of items must split. Doing that early avoids crashing the
  /// splitter when it tries to recurse on huge collection literals.
  void forceRules() => _handleHardSplit();

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nestExpression() {
    _stack.nest();
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    _stack.unnest();
  }

  /// Marks the selection starting point as occurring [fromEnd] characters to
  /// the left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void startSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.startSelectionFromEnd(fromEnd);
  }

  /// Marks the selection ending point as occurring [fromEnd] characters to the
  /// left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void endSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.endSelectionFromEnd(fromEnd);
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode end() {
    if (_chunks.isNotEmpty) {
      _writeHardSplit();
      _splitLines();
    }

    // Be a good citizen, end with a newline.
    if (_source.isCompilationUnit) _buffer.write(_formatter.lineEnding);

    // If we haven't hit the beginning and/or end of the selection yet, they
    // must be at the very end of the code.
    if (_source.selectionStart != null) {
      if (_selectionStart == null) {
        _selectionStart = _buffer.length;
      }

      if (_selectionLength == null) {
        _selectionLength = _buffer.length - _selectionStart;
      }
    }

    return new SourceCode(_buffer.toString(),
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: _selectionStart,
        selectionLength: _selectionLength);
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
      case Whitespace.space:
        _writeText(" ");
        break;

      case Whitespace.newline:
        _writeHardSplit();
        break;

      case Whitespace.nestedNewline:
        _writeHardSplit(nest: true);
        break;

      case Whitespace.newlineFlushLeft:
        _writeHardSplit(flushLeft: true);
        break;

      case Whitespace.twoNewlines:
        _writeHardSplit(double: true);
        break;

      case Whitespace.spaceOrNewline:
      case Whitespace.oneOrTwoNewlines:
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

    // Otherwise, it gets a space if the following token is not a delimiter or
    // the empty string, for EOF.
    return token != ")" && token != "]" && token != "}" &&
           token != "," && token != ";" && token != "";
  }

  /// Appends a hard split with the current indentation and nesting (the latter
  /// only if [nest] is `true`).
  ///
  /// If [double] is `true`, a double-split (i.e. a blank line) is output.
  ///
  /// If [flushLeft] is `true`, then the split will always cause the next line
  /// to be at column zero. Otherwise, it uses the normal indentation and
  /// nesting behavior.
  void _writeHardSplit({bool nest: false, bool double: false, bool flushLeft}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;
    _writeSplit(new HardSplitRule(),
        nest: nest, flushLeft: flushLeft, isDouble: double);
  }

  /// Ends the current chunk (if any) with the given split information.
  ///
  /// Returns the chunk.
  Chunk _writeSplit(Rule rule,
      {bool nest, bool flushLeft, bool isDouble, bool spaceWhenUnsplit}) {
    if (_chunks.isEmpty) return null;

    var chunk = _chunks.last;
    chunk.applySplit(_stack, rule,
        nest: nest,
        flushLeft: flushLeft,
        isDouble: isDouble,
        spaceWhenUnsplit: spaceWhenUnsplit);

    // Keep track of which chunks are owned by the rule.
    if (rule is! HardSplitRule) {
      _ruleChunks.putIfAbsent(rule, () => []).add(chunk);
    }

    if (chunk.isHardSplit) _handleHardSplit();

    return chunk;
  }

  /// Writes [text] to either the current chunk or a new one if the current
  /// chunk is complete.
  void _writeText(String text) {
    if (_chunks.isNotEmpty && _chunks.last.canAddText) {
      _chunks.last.appendText(text);
    } else {
      _chunks.add(new Chunk(text));
    }
  }

  /// Takes all of the chunks and breaks them into sublists that can be line
  /// split individually.
  ///
  /// This should only be called once, after all of the chunks have been
  /// written.
  void _splitLines() {
    // Make sure we don't split the line in the middle of a rule.
    var rules = _chunks.map((chunk) => chunk.rule).toSet();
    var ruleSpanningIndexes = new Set();
    for (var rule in rules) {
      if (rule.start == null) continue;
      for (var i = rule.start; i < rule.end; i++) {
        ruleSpanningIndexes.add(i);
      }
    }

    // For each independent set of chunks, see if there are any rules in them
    // that we want to preemptively harden. This is basically to send smaller
    // batches of chunks to LineSplitter in cases where the code is deeply
    // nested or complex.
    var start = 0;
    for (var i = 1; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (!chunk.endsLine) continue;
      if (ruleSpanningIndexes.contains(i)) continue;

      _preemptRules(start, i);
      start = i;
    }

    if (start < _chunks.length) {
      _preemptRules(start, _chunks.length);
    }

    // Now that we know what hard splits there will be, break the chunks into
    // independently splittable lines.
    var bufferedNewlines = 0;
    var beginningIndent = _formatter.indent;

    start = 0;
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];

      if (!chunk.endsLine) continue;
      if (ruleSpanningIndexes.contains(i)) continue;

      // Write the newlines required by the previous line.
      for (var i = 0; i < bufferedNewlines; i++) {
        _buffer.write(_formatter.lineEnding);
      }

      _completeLine(beginningIndent, _chunks.sublist(start, i + 1));

      // Get ready for the next line.
      bufferedNewlines = chunk.isDouble ? 2 : 1;
      beginningIndent = chunk.absoluteIndent;
      start = i + 1;
    }

    if (start < _chunks.length) {
      _completeLine(beginningIndent, _chunks.sublist(start, _chunks.length));
    }
  }

  /// Takes the first [length] of the chunks with leading [indent], removes
  /// them, and runs the [LineSplitter] on them.
  void _completeLine(int indent, List<Chunk> chunks) {
    // We know unused nesting levels will never be used now, so flatten them.
    _flattenNestingLevels(chunks);

    if (debug.traceFormatter) {
      debug.log(debug.green("\nWriting:"));
      debug.dumpChunks(chunks);
      debug.log();
    }

    var splitter = new LineSplitter(
        _formatter.lineEnding, _formatter.pageWidth, chunks, indent);
    var selection = splitter.apply(_buffer);

    if (selection[0] != null) {
      _selectionStart = selection[0];
    }

    if (selection[1] != null) {
      _selectionLength = selection[1] -_selectionStart;
    }
  }

  /// Removes any unused nesting levels from [chunks].
  ///
  /// The line splitter considers every possible combination of mapping
  /// indentation to nesting levels when trying to find the best solution. For
  /// example, it may assign 4 spaces of indentation to level 1, 8 spaces to
  /// level 3, etc.
  ///
  /// It's fairly common for a nesting level to not actually appear at the
  /// boundary of a chunk. The source visitor may enter more than one level of
  /// nesting at a point where a split cannot happen. In that case, there's no
  /// point in trying to assign an indentation level to that nesting level. It
  /// will never be used because no line will begin at that level of
  /// indentation.
  ///
  /// Worse, if the splitter *does* consider these levels, it can dramatically
  /// increase solving time. We can't determine which nesting levels will get
  /// used eagerly since a level may not be used until later. Instead, when we
  /// bounce all the way back to no nesting, this goes through and renumbers
  /// the nesting levels of all of the preceding chunks.
  void _flattenNestingLevels(List<Chunk> chunks) {
    var nestingLevels = chunks
        .map((chunk) => chunk.nesting)
        .where((nesting) => nesting != 0)
        .toSet()
        .toList();
    nestingLevels.sort();

    var nestingMap = {0: 0};
    for (var i = 0; i < nestingLevels.length; i++) {
      nestingMap[nestingLevels[i]] = i + 1;
    }

    for (var chunk in chunks) {
      chunk.flattenNesting(nestingMap);
    }
  }

  /// Preemptively hardens rules in the range of chunks from [start] to [end]
  /// (half-inclusive) if there will certainly be no solution that allows them
  /// to remain unsplit.
  ///
  /// For each rule, we look at the span of chunks it covers. If that range is
  /// longer than the page width, than the rule is preemptively hardened now.
  /// Doing this now lets us break the chunks into separate smaller lines to
  /// hand off to the line splitter, which is much faster.
  ///
  /// This may discard a more optimal solution in some cases. When a rule is
  /// hardened, it is *fully* hardened. There may have been a solution where
  /// only some of a rule's chunks needed to be split (for example, not fully
  /// breaking an argument list). This won't consider those kinds of solution
  /// To avoid this, pre-emption only kicks in for lines that look like they
  /// will be hard to solve directly.
  ///
  /// Returns the indexes of chunks that got hardened.
  // TODO(bob): Eventually we probably only want to do this for rules
  // that have "multisplit"-like behavior where an inner split always
  // implies that it gets split.
  // TODO(bob): The fact that this generates non-optimal solutions is a drag.
  // Can we do something better?
  void _preemptRules(int start, int end) {
    // TODO(bob): Should be rule.splitsOnInnerRules instead of is! HardSplitRule.
    // But that significantly regresses perf at least until we have better
    // handling for method chains.
    var rules = _chunks
        .sublist(start, end)
        .map((chunk) => chunk.rule)
        .where((rule) => rule is! HardSplitRule)
        .toSet();

    var values = rules.fold(1, (value, rule) => value * rule.numValues);

    // If the number of possible solutions is reasonable, don't preempt any.
    if (values < 4096) return;

    // Find the rules that contain too much.
    for (var rule in rules) {
      var length = 0;
      for (var i = rule.start + 1; i <= rule.end; i++) {
        // TODO(bob): What if the chunk has a hard split?
        length += _chunks[i].length;
        if (length > pageWidth) {
          // TODO(bob): This is incorrect when the rule isn't a Simple rule.
          // For example it will harden an argument list to full one-per-line
          // even if the arg list could fit when split to two lines.
          _hardenRule(rule);
          break;
        }
      }
    }
  }

  /// Hardens any active rules that care when a hard split occurs within them.
  void _handleHardSplit() {
    // Replace each ongoing rule with a hard split if it wants to split when
    // it contains an inner split.
    for (var i = 0; i < _rules.length; i++) {
      var rule = _rules[i];
      if (rule.splitsOnInnerRules) {
        _rules[i] = new HardSplitRule();
        _hardenRule(rule);
      }
    }
  }

  /// Hardens every [Chunk] that uses [rule].
  void _hardenRule(Rule rule) {
    if (!_ruleChunks.containsKey(rule)) return;

    for (var chunk in _ruleChunks[rule]) chunk.harden();

    // Note that other rules may still imply the now-discarded rule. We could
    // clean those out, but it takes time to do so and it's harmless to leave
    // them alone. Since removing them noticeably affects perf, we just ignore
    // them.
  }
}
