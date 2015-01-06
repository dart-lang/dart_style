// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Internal debugging utilities.
library dart_style.src.debug;

import 'chunk.dart';
import 'line_prefix.dart';
import 'line_splitter.dart';

/// Set this to `true` to turn out diagnostic output while formatting.
bool debugFormatter = false;

bool useAnsiColors = false;

const unicodeSection = "\u00a7";
const unicodeMidDot = "\u00b7";

/// Constants for ANSI color escape codes.
class Color {
  static final cyan = _color("\u001b[36m");
  static final gray = _color("\u001b[1;30m");
  static final green = _color("\u001b[32m");
  static final red = _color("\u001b[31m");
  static final magenta = _color("\u001b[35m");
  static final none = _color("\u001b[0m");
  static final noColor = _color("\u001b[39m");
  static final bold = _color("\u001b[1m");
}

/// Prints [chunks] to stdout, one chunk per line, with detailed information
/// about each chunk.
void dumpChunks(List<Chunk> chunks) {
  var i = 0;
  for (var chunk in chunks) {
    print("$i: $chunk");
    i++;
  }
}

/// Prints [chunks] to stdout as a single line with non-printing chunks made
/// visible.
void dumpLine(List<Chunk> chunks,
    [int indent = 0, LinePrefix prefix, Set<SplitParam> splits]) {
  if (prefix == null) prefix = new LinePrefix();
  if (splits == null) splits = new Set();

  var buffer = new StringBuffer()
    ..write(Color.gray)
    ..write("| " * prefix.getNextLineIndent(chunks, indent))
    ..write(Color.none);

  for (var i = prefix.length; i < chunks.length; i++) {
    var chunk = chunks[i];

    buffer.write(chunk.text);

    if (chunk.isSoftSplit) {
      var color = splits.contains(chunk.param) ? Color.green : Color.gray;

      buffer.write("$color$unicodeSection${chunk.param.cost}");
      if (chunk.nesting != -1) buffer.write(":${chunk.nesting}");
      buffer.write("${Color.none}");
    } else if (chunk.isHardSplit) {
      buffer.write("${Color.magenta}\\n${"->" * chunk.indent}${Color.none}");
    }
  }

  print(buffer);
}

/// Convert the line to a [String] representation.
///
/// It will determine how best to split it into multiple lines of output and
/// return a single string that may contain one or more newline characters.
void dumpLines(List<Chunk> chunks,
    [int indent = 0, LinePrefix prefix, SplitSet splits]) {
  if (prefix == null) prefix = new LinePrefix();
  if (splits == null) splits = new SplitSet();

  var buffer = new StringBuffer()
    ..write(Color.gray)
    ..write("| " * indent)
    ..write(Color.none);

  for (var i = prefix.length; i < chunks.length - 1; i++) {
    var chunk = chunks[i];
    buffer.write(chunk.text);

    if (splits.shouldSplitAt(i)) {
      for (var j = 0; j < (chunk.isDouble ? 2 : 1); j++) {
        buffer.writeln();

        indent = chunk.indent + splits.getNesting(i);
        buffer
          ..write(Color.gray)
          ..write("| " * indent)
          ..write(Color.none);
      }

      // Should have a valid set of splits when we get here.
      assert(indent != invalidSplits);
    } else {
      if (chunk.spaceWhenUnsplit) buffer.write(" ");
    }
  }

  buffer.write(chunks.last.text);
  print(buffer);
}

String _color(String ansiEscape) => useAnsiColors ? ansiEscape : "";
