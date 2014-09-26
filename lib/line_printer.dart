// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.line_breaker;

import 'line.dart';

/// Converts a [Line] to a single flattened [String].
///
/// By default, does not line breaking.
class LinePrinter {
  const LinePrinter();

  /// Convert this [line] to a [String] representation.
  String printLine(Line line) => line.tokens.join();
}

/// A line breaking [LinePrinter].
class LineBreaker extends LinePrinter {
  final int maxLength;

  /// Creates a new breaker that tries to fit lines within [maxLength].
  LineBreaker(this.maxLength);

  String printLine(Line line) {
    var buffer = new StringBuffer();
    var chunks = breakLine(line);
    for (var i = 0; i < chunks.length; i++) {
      var chunk = chunks[i];
      if (i > 0) {
        buffer.write(indent(chunk, chunk.indent));
      } else {
        buffer.write(chunk);
      }
    }
    return buffer.toString();
  }

  String indent(Chunk chunk, int level) => "\n${getIndentString(level)}$chunk";

  List<Chunk> breakLine(Line line) {
    var tokens = _mergeTokens(line.tokens);
    var chunks = <Chunk>[new Chunk(line.indentLevel, tokens)];

    // Try SINGLE_SPACE_WEIGHT.
    {
      var chunk = chunks[0];
      if (chunk.length > maxLength) {
        for (var i = 0; i < tokens.length; i++) {
          var token = tokens[i];
          if (token is! SpaceToken) continue;
          if (token.breakWeight != SINGLE_SPACE_WEIGHT) continue;

          var beforeChunk = chunk.subChunk(chunk.indent, 0, i);
          var restChunk = chunk.subChunk(chunk.indent + 2, i + 1);

          // Check if `init` in `var v = init;` fits a line.
          if (restChunk.length < maxLength) {
            return [beforeChunk, restChunk];
          }

          // Check if `var v = method(` in `var v = method(args)` fits.
          var weight = chunk.findMinSpaceWeight();
          if (chunk.getLengthToSpaceWithWeight(weight) > maxLength) {
            chunks = [beforeChunk, restChunk];
          }

          // Done anyway.
          break;
        }
      }
    }

    // Other spaces.
    while (true) {
      var newChunks = <Chunk>[];
      var hasChanges = false;

      for (var chunk in chunks) {
        tokens = chunk.tokens;
        if (chunk.length > maxLength) {
          if (chunk.hasAnySpace()) {
            var weight = chunk.findMinSpaceWeight();
            var newIndent = chunk.indent;
            if (weight == DEFAULT_SPACE_WEIGHT) {
              var start = 0;
              var length = 0;
              for (var i = 0; i < tokens.length; i++) {
                var token = tokens[i];
                if (token is SpaceToken &&
                    token.breakWeight == weight &&
                    i < tokens.length - 1) {
                  var nextToken = tokens[i + 1];
                  if (length + token.length + nextToken.length > maxLength) {
                    newChunks.add(chunk.subChunk(newIndent, start, i));
                    newIndent = chunk.indent + 2;
                    start = i + 1;
                    length = 0;
                    continue;
                  }
                }
                length += token.length;
              }
              if (start < tokens.length) {
                newChunks.add(chunk.subChunk(newIndent, start));
              }
            } else {
              var part = [];
              var start = 0;
              for (var i = 0; i < tokens.length; i++) {
                var token = tokens[i];
                if (token is SpaceToken && token.breakWeight == weight) {
                  newChunks.add(chunk.subChunk(newIndent, start, i));
                  newIndent = chunk.indent + 2;
                  start = i + 1;
                }
              }

              if (start < tokens.length) {
                newChunks.add(chunk.subChunk(newIndent, start));
              }
            }
          } else {
            newChunks.add(chunk);
          }
        } else {
          newChunks.add(chunk);
        }

        if (newChunks.length > chunks.length) hasChanges = true;
      }

      if (!hasChanges) break;
      chunks = newChunks;
    }
    return chunks;
  }

  /// Merges tokens that don't affect line breaking.
  ///
  /// Since most tokens aren't places where line breaks can occur, we don't
  /// need to treat them individually when finding break points. This takes
  /// contiguous spans of non-breaking tokens and merges them.
  List<LineToken> _mergeTokens(List<LineToken> tok) {
    var tokens = <LineToken>[];
    var current;

    for (var token in tok) {
      // Split on breakable space tokens.
      if (token is SpaceToken &&
          token.breakWeight != UNBREAKABLE_SPACE_WEIGHT) {
        // The current token is done being accumulated.
        if (current != null) {
          tokens.add(current);
          current = null;
        }

        // This space is its own token.
        tokens.add(token);
      } else {
        // Any other token can't affect line breaking, so we can combine it
        // with the previous one.
        if (current == null) {
          current = token;
        } else {
          current = new LineToken(current.value + token.value);
        }
      }
    }

    if (current != null) tokens.add(current);

    return tokens;
  }
}
