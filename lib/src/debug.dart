// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Internal debugging utilities.
library dart_style.src.debug;

import 'dart:math' as math;

import 'chunk.dart';
import 'line_splitting/rule_set.dart';
import 'rule/rule.dart';

/// Set this to `true` to turn on diagnostic output while building chunks.
bool traceChunkBuilder = false;

/// Set this to `true` to turn on diagnostic output while writing lines.
bool traceLineWriter = false;

/// Set this to `true` to turn on diagnostic output while line splitting.
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
void dumpChunks(int start, List<Chunk> chunks) {
  if (chunks.isEmpty) return;

  // Show the spans as vertical bands over their range.
  var spans = new Set();
  addSpans(chunks) {
    for (var chunk in chunks) {
      spans.addAll(chunk.spans);

      addSpans(chunk.blockChunks);
    }
  }

  addSpans(chunks);

  spans = spans.toList();

  var rules = chunks
      .map((chunk) => chunk.rule)
      .where((rule) => rule != null && rule is! HardSplitRule)
      .toSet();

  var rows = [];

  addChunk(chunk, prefix, index) {
    var row = [];
    row.add("$prefix$index:");

    if (chunk.text.length > 70) {
      row.add(chunk.text.substring(0, 70));
    } else {
      row.add(chunk.text);
    }

    var spanBars = "";
    for (var span in spans) {
      spanBars += chunk.spans.contains(span) ? "|" : " ";
    }
    row.add(spanBars);

    writeIf(predicate, String callback()) {
      if (predicate) {
        row.add(callback());
      } else {
        row.add("");
      }
    }

    if (chunk.rule != null) {
      row.add(chunk.isHardSplit ? "" : chunk.rule.toString());

      var outerRules = chunk.rule.outerRules.toSet().intersection(rules);
      writeIf(outerRules.isNotEmpty, () => "-> ${outerRules.join(" ")}");
    } else {
      row.add("(no rule)");

      // Outer rules.
      row.add("");
    }

    writeIf(chunk.indent != null && chunk.indent != 0,
        () => "indent ${chunk.indent}");

    writeIf(chunk.nesting != null && chunk.nesting != 0,
        () => "nest ${chunk.nesting}");

    writeIf(chunk.flushLeft != null && chunk.flushLeft, () => "flush");

    rows.add(row);

    for (var j = 0; j < chunk.blockChunks.length; j++) {
      addChunk(chunk.blockChunks[j], "$prefix$index.", j);
    }
  }

  var i = start;
  for (var chunk in chunks) {
    addChunk(chunk, "", i);
    i++;
  }

  var rowWidths = new List.filled(rows.first.length, 0);
  for (var row in rows) {
    for (var i = 0; i < row.length; i++) {
      rowWidths[i] = math.max(rowWidths[i], row[i].length);
    }
  }

  var buffer = new StringBuffer();
  for (var row in rows) {
    for (var i = 0; i < row.length; i++) {
      var cell = row[i].padRight(rowWidths[i]);

      if (i != 1) cell = gray(cell);

      buffer.write(cell);
      buffer.write("  ");
    }

    buffer.writeln();
  }

  print(buffer.toString());
}

/// Convert the line to a [String] representation.
///
/// It will determine how best to split it into multiple lines of output and
/// return a single string that may contain one or more newline characters.
void dumpLines(List<Chunk> chunks, int firstLineIndent, SplitSet splits) {
  var buffer = new StringBuffer();

  writeIndent(indent) => buffer.write(gray("| " * (indent ~/ 2)));

  writeChunksUnsplit(List<Chunk> chunks) {
    for (var chunk in chunks) {
      buffer.write(chunk.text);
      if (chunk.spaceWhenUnsplit) buffer.write(" ");

      // Recurse into the block.
      writeChunksUnsplit(chunk.blockChunks);
    }
  }

  writeIndent(firstLineIndent);

  for (var i = 0; i < chunks.length - 1; i++) {
    var chunk = chunks[i];
    buffer.write(chunk.text);

    if (splits.shouldSplitAt(i)) {
      for (var j = 0; j < (chunk.isDouble ? 2 : 1); j++) {
        buffer.writeln();
        writeIndent(splits.getColumn(i));
      }
    } else {
      writeChunksUnsplit(chunk.blockChunks);

      if (chunk.spaceWhenUnsplit) buffer.write(" ");
    }
  }

  buffer.write(chunks.last.text);
  log(buffer);
}

String _color(String ansiEscape) => useAnsiColors ? ansiEscape : "";
