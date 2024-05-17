// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../profile.dart';
import 'fast_hash.dart';
import 'marking_scheme.dart';
import 'nesting_level.dart';
import 'rule/rule.dart';
import 'selection.dart';

/// A chunk of non-breaking output text that may begin on a newline.
///
/// Chunks are created by [ChunkBuilder] and fed into [LineSplitter]. Each
/// contains the data describing where the chunk should appear when starting a
/// new line, how desireable it is to split, and the subsequent text for that
/// line.
///
/// Line splitting before a chunk comes in a few different forms.
///
/// *   A "hard" split is a mandatory newline. The formatted output will contain
///     at least one newline before the chunk's text.
/// *   A "soft" split is a discretionary newline. If a line doesn't fit within
///     the page width, one or more soft splits may be turned into newlines to
///     wrap the line to fit within the bounds. If a soft split is not turned
///     into a newline, it may instead appear as a space or zero-length string
///     in the output, depending on [spaceWhenUnsplit].
/// *   A "double" split expands to two newlines. In other words, it leaves a
///     blank line in the output. Hard or soft splits may be doubled. This is
///     determined by [isDouble].
///
/// A split controls the leading spacing of the line before the chunk's text,
/// both block-based [indent] and expression-wrapping-based [nesting].
class Chunk extends Selection {
  /// The literal text output for the chunk.
  @override
  String get text => _text;
  String _text;

  /// The number of characters of indentation from the left edge of the block
  /// that contains this chunk.
  ///
  /// For top level chunks that are not inside any block, this also includes
  /// leading indentation.
  final int indent;

  /// The expression nesting level preceding this chunk.
  ///
  /// This is used to determine how much to increase the indentation when a
  /// line starts at this chunk. A single statement may be indented multiple
  /// times if the splits occur in more deeply nested expressions, for example:
  ///
  ///     // 40 columns                           |
  ///     someFunctionName(argument, argument,
  ///         argument, anotherFunction(argument,
  ///             argument));
  final NestingLevel nesting;

  /// The [Rule] that controls when a split should occur before this chunk.
  ///
  /// Multiple splits may share a [Rule].
  final Rule rule;

  /// Whether or not an extra blank line should be output before this chunk if
  /// it splits.
  bool get isDouble => _isDouble;
  bool _isDouble;

  /// If `true`, then the line beginning with this chunk should always be at
  /// column zero regardless of any indentation or expression nesting.
  ///
  /// Used for multi-line strings and commented out code.
  bool get flushLeft => _flushLeft;
  bool _flushLeft;

  /// Whether this chunk should prepend an extra space if it does not split.
  ///
  /// This is `true`, for example, in a chunk following a ",".
  bool get spaceWhenUnsplit => _spaceWhenUnsplit;
  bool _spaceWhenUnsplit;

  /// Whether this chunk marks the end of a range of chunks that can be line
  /// split independently of the following chunks.
  bool get canDivide => _canDivide;
  bool _canDivide = true;

  /// The number of characters in this chunk when unsplit.
  int get length => (_spaceWhenUnsplit ? 1 : 0) + _text.length;

  /// The unsplit length of all of this chunk's block contents.
  ///
  /// Does not include this chunk's own length, just the length of its child
  /// block chunks (recursively).
  int get unsplitBlockLength => 0;

  /// The [Span]s that contain this chunk.
  final spans = <Span>[];

  /// Creates a new empty chunk with the given split properties.
  Chunk(this.rule, this.indent, this.nesting,
      {required bool space, required bool flushLeft, required bool isDouble})
      : _text = '',
        _flushLeft = flushLeft,
        _isDouble = isDouble,
        _spaceWhenUnsplit = space {
    Profile.count('Create Chunk');
  }

  /// Creates a dummy chunk.
  ///
  /// This is returned in some places by [ChunkBuilder] when there is no useful
  /// chunk to yield and it will not end up being used by the caller anyway.
  Chunk.dummy()
      : _text = '(dummy)',
        rule = Rule.dummy,
        indent = 0,
        nesting = NestingLevel(),
        _spaceWhenUnsplit = false,
        _flushLeft = false,
        _isDouble = false {
    Profile.count('Create Chunk');
  }

  /// Append [text] to the end of the chunk's text.
  void appendText(String text) {
    _text += text;
  }

  /// Updates the split information for a previously created chunk in response
  /// to a split from a comment.
  void updateSplit({bool? flushLeft, bool isDouble = false, bool? space}) {
    assert(text.isEmpty);

    if (flushLeft != null) _flushLeft = flushLeft;

    // Don't discard an already known blank newline, but do potentially add one.
    if (isDouble) _isDouble = true;

    if (space != null) _spaceWhenUnsplit = space;
  }

  /// Returns `true` if this chunk is a block whose children should be
  /// expression indented given a set of rule values provided by [getValue].
  ///
  /// [getValue] takes a [Rule] and returns the chosen split state value for
  /// that [Rule].
  bool indentBlock(int Function(Rule) getValue) => false;

  /// Prevent the line splitter from diving at this chunk.
  ///
  /// This should be called on any chunk where line splitting choices before
  /// and after this chunk relate to each other.
  void preventDivide() {
    _canDivide = false;
  }

  @override
  String toString() {
    var parts = [
      'indent:$indent',
      if (spaceWhenUnsplit) 'space',
      if (isDouble) 'double',
      if (flushLeft) 'flush',
      '$rule${rule.isHardened ? '!' : ''}',
      if (rule.constrainedRules.isNotEmpty)
        "-> ${rule.constrainedRules.join(' ')}"
    ];

    return '[${parts.join(' ')}] `$text`';
  }
}

/// A [Chunk] containing a list of nested "child" chunks that are formatted
/// independently of the surrounding chunks.
///
/// This is used for blocks, function expressions, collection literals, etc.
/// Basically, anywhere we have a delimited body of code whose formatting
/// doesn't depend on how the surrounding code is formatted except to determine
/// indentation.
///
/// This chunk's own text is the closing delimiter of the block, so its
/// children come before itself. For example, given this code:
///
///     main() {
///       var list = [
///         element,
///       ];
///     }
///
/// It is organized into a tree of chunks like so:
///
///    - Chunk           "main() {"
///    - BlockChunk
///      |- Chunk          "var list = ["
///      |- BlockChunk
///      |  |- Chunk         "element,"
///      |  '- (text)      "];"
///      '- (text)       "}"
class BlockChunk extends Chunk {
  /// If this block is for a collection literal in an argument list, this will
  /// be the chunk preceding this literal argument.
  ///
  /// That chunk is owned by the argument list and if it splits, this collection
  /// may need extra expression-level indentation.
  final Chunk? argument;

  /// The child chunks in this block.
  final List<Chunk> children = [];

  BlockChunk(this.argument, super.rule, super.indent, super.nesting,
      {required super.space, required super.flushLeft})
      : super(isDouble: false);

  /// The unsplit length of all of this chunk's block contents.
  ///
  /// Does not include this chunk's own length, just the length of its child
  /// block chunks (recursively).
  @override
  int get unsplitBlockLength {
    var length = 0;
    for (var chunk in children) {
      length += chunk.length + chunk.unsplitBlockLength;
    }

    return length;
  }

  @override
  bool indentBlock(int Function(Rule) getValue) {
    var argument = this.argument;
    if (argument == null) return false;

    // There may be no rule if the block occurs inside a string interpolation.
    // In that case, it's not clear if anything will look particularly nice, but
    // expression nesting is probably marginally better.
    var rule = argument.rule;
    if (rule == Rule.dummy) return true;

    return rule.isSplit(getValue(rule), argument);
  }
}

/// The in-progress state for a [Span] that has been started but has not yet
/// been completed.
class OpenSpan {
  /// Index of the first chunk contained in this span.
  final int start;

  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  OpenSpan(this.start, this.cost);

  @override
  String toString() => 'OpenSpan($start, \$$cost)';
}

/// Delimits a range of chunks that must end up on the same line to avoid an
/// additional cost.
///
/// These are used to encourage the line splitter to try to keep things
/// together, like parameter lists and binary operator expressions.
///
/// This is a wrapper around the cost so that spans have unique identities.
/// This way we can correctly avoid paying the cost multiple times if the same
/// span is split by multiple chunks.
///
/// Spans can be marked during processing in an algorithm but should be left
/// unmarked when the algorithm finishes to make marking work in subsequent
/// calls.
class Span extends FastHash with Markable {
  /// The cost applied when the span is split across multiple lines or `null`
  /// if the span is for a multisplit.
  final int cost;

  Span(this.cost);

  @override
  String toString() => '$id\$$cost';
}
