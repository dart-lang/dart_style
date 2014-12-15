// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Internal debugging utilities.
library dart_style.src.debug;

import 'chunk.dart';
import 'line_splitter.dart';

/// Set this to `true` to turn out diagnostic output while formatting.
bool debugFormatter = false;

bool useAnsiColors = false;

const UNICODE_SECT = "\u00a7";
const UNICODE_MIDDOT = "\u00b7";
const UNICODE_LASQUO = "\u2039";
const UNICODE_RASQUO = "\u203a";

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

    if (chunk is TextChunk) {
      buffer.write(chunk.text);
    } else if (chunk.isSoftSplit) {
      var split = chunk as SplitChunk;
      var color = splits.contains(split.param) ? Color.green : Color.gray;

      buffer.write("$color$UNICODE_SECT${split.param.cost}");
      if (split.nesting != -1) {
        buffer.write(":${split.nesting}");
      }
      buffer.write("${Color.none}");
    } else if (chunk.isHardSplit) {
      buffer.write("${Color.magenta}\\n${"->" * chunk.indent}${Color.none}");
    } else {
      // Unexpected chunk type.
      buffer.write("${Color.red}$UNICODE_LASQUO$chunk$UNICODE_RASQUO"
          "${Color.none}");
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

  indent = prefix.getNextLineIndent(chunks, indent);

  var buffer = new StringBuffer();

  // Write each chunk in the line.
  for (var i = prefix.length; i < chunks.length; i++) {
    var chunk = chunks[i];

    if (splits.shouldSplitAt(i)) {
      var split = chunks[i] as SplitChunk;
      buffer.writeln();
      if (split.isDouble) buffer.writeln();

      indent = split.indent + splits.getNesting(i);
    } else {
      // Now that we know the line isn't empty, write the leading indentation.
      if (indent > 0) {
        buffer
        ..write(Color.gray)
        ..write("| " * indent)
        ..write(Color.none);
      } else if (indent == INVALID_SPLITS) {
        buffer.write("${Color.red}!!${Color.none}");
      }

      buffer.write(chunk.text);
      indent = 0;
    }
  }

  print(buffer);
}

String _color(String ansiEscape) => useAnsiColors ? ansiEscape : "";
