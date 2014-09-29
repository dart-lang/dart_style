// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.line_breaker;

import 'line.dart';

/// Converts a [Line] to a single flattened [String].
class LinePrinter {
  final int pageWidth;

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LinePrinter({this.pageWidth});

  /// Convert this [line] to a [String] representation.
  String printLine(Line line) {
    var buffer = new StringBuffer();

    var length = line.unsplitLength;
    if (length <= pageWidth) {
      // No splitting needed.
      buffer.write(" " * (line.indent * SPACES_PER_INDENT));
      buffer.writeAll(line.chunks);
    } else {
      // Determine how to split the lines.
      // TODO(rnystrom): Do real logic here. Right now, it just splits
      // everything.
      for (var splitter in line.splitters) splitter.isSplit = true;

      var indent = line.indent;

      writeIndent() {
        buffer.write(" " * (indent * SPACES_PER_INDENT));
      }

      writeIndent();
      for (var chunk in line.chunks) {
        if (chunk is TextChunk) {
          buffer.write(chunk.text);
        } else {
          var split = chunk as SplitChunk;
          if (split.splitter.isSplit) {
            buffer.write("\n");
            indent += split.indent;
            writeIndent();
          } else {
            buffer.write(chunk.text);
          }
        }
      }
    }

    return buffer.toString();
  }
}
