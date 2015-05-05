// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Internal debugging utilities.
library dart_style.src.debug;

import 'chunk.dart';
import 'line_prefix.dart';
import 'line_splitter.dart';

/// Set this to `true` to turn out diagnostic output while formatting.
bool traceFormatter = false;

/// Set this to `true` to turn out diagnostic output while line splitting.
bool traceSplitter = false;

bool useAnsiColors = false;

const unicodeSection = "\u00a7";
const unicodeMidDot = "\u00b7";

/// The whitespace prefixing each line of output.
String _indent = "";

void indent() {
  _indent = "  $_indent";
}

void unindent() {
  _indent = _indent.substring(2);
}

/// Constants for ANSI color escape codes.
final _cyan = _color("\u001b[36m");
final _gray = _color("\u001b[1;30m");
final _green = _color("\u001b[32m");
final _red = _color("\u001b[31m");
final _magenta = _color("\u001b[35m");
final _none = _color("\u001b[0m");
final _noColor = _color("\u001b[39m");
final _bold = _color("\u001b[1m");

/// Prints [message] to stdout with each line correctly indented.
void log([message]) {
  if (message == null) {
    print("");
    return;
  }

  print(_indent + message.toString().replaceAll("\n", "\n$_indent"));
}

/// Wraps [message] in gray ANSI escape codes if enabled.
String gray(message) => "$_gray$message$_none";

/// Wraps [message] in green ANSI escape codes if enabled.
String green(message) => "$_green$message$_none";

/// Wraps [message] in bold ANSI escape codes if enabled.
String bold(message) => "$_bold$message$_none";

/// Prints [chunks] to stdout, one chunk per line, with detailed information
/// about each chunk.
void dumpChunks(List<Chunk> chunks) {
  var i = 0;
  for (var chunk in chunks) {
    log("$i: $chunk");
    i++;
  }
}

/// Convert the line to a [String] representation.
///
/// It will determine how best to split it into multiple lines of output and
/// return a single string that may contain one or more newline characters.
void dumpLines(List<Chunk> chunks, int indent, LinePrefix prefix,
    SplitSet splits) {
  var buffer = new StringBuffer();

  startLine(nextIndent) {
    indent = nextIndent;
    buffer.write(gray("| " * indent));
  }

  startLine(indent);

  for (var i = prefix.length; i < chunks.length - 1; i++) {
    var chunk = chunks[i];
    buffer.write(chunk.text);

    if (splits.shouldSplitAt(i)) {
      for (var j = 0; j < (chunk.isDouble ? 2 : 1); j++) {
        buffer.writeln();
        startLine(chunk.indent + splits.getNesting(i));
      }

      // Should have a valid set of splits when we get here.
      assert(indent != invalidSplits);
    } else {
      if (chunk.spaceWhenUnsplit) buffer.write(" ");
    }
  }

  buffer.write(chunks.last.text);
  log(buffer);
}

String _color(String ansiEscape) => useAnsiColors ? ansiEscape : "";
