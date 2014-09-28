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
  final int pageWidth;

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LineBreaker(this.pageWidth);

  String printLine(Line line) {
    var buffer = new StringBuffer();
    var chunks = breakLine(line);
    for (var i = 0; i < chunks.length; i++) {
      var chunk = chunks[i];
      if (i > 0) buffer.writeln();

      if (chunk.tokens.isNotEmpty) {
        buffer.write(chunk.indentString);
      }

      buffer.write(chunk);
    }

    return buffer.toString();
  }

  List<Chunk> breakLine(Line line) {
    var tokens = line.tokens;
    var chunks = <Chunk>[new Chunk(line.indent, tokens)];

    // Try SINGLE_SPACE_WEIGHT.
    {
      var chunk = chunks[0];
      if (chunk.length > pageWidth) {
        for (var i = 0; i < tokens.length; i++) {
          var token = tokens[i];
          if (token is! SpaceToken) continue;
          if (token.weight != Weight.single) continue;

          var beforeChunk = chunk.subChunk(chunk.indent, 0, i);
          var restChunk = chunk.subChunk(chunk.indent + 2, i + 1);

          // Check if `init` in `var v = init;` fits a line.
          if (restChunk.length < pageWidth) {
            return [beforeChunk, restChunk];
          }

          // Check if `var v = method(` in `var v = method(args)` fits.
          var weight = chunk.minSpaceWeight;
          if (chunk.getLengthToSpaceWithWeight(weight) > pageWidth) {
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
        if (chunk.length > pageWidth) {
          if (chunk.hasAnySpace) {
            var weight = chunk.minSpaceWeight;
            var newIndent = chunk.indent;
            if (weight == Weight.normal) {
              var start = 0;
              var length = chunk.indent * SPACES_PER_INDENT;
              for (var i = 0; i < tokens.length; i++) {
                var token = tokens[i];
                if (token is SpaceToken && token.weight == weight &&
                    i < tokens.length - 1) {
                  var nextToken = tokens[i + 1];
                  if (length + token.length + nextToken.length > pageWidth) {
                    newChunks.add(chunk.subChunk(newIndent, start, i));
                    newIndent = chunk.indent + 2;
                    start = i + 1;
                    length = newIndent * SPACES_PER_INDENT;
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
                if (token is SpaceToken && token.weight == weight) {
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
}
