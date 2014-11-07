// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.file_util;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

const DEFAULT_LINE_LENGTH = 80;
const DEFAULT_OVERWRITE = false;

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
void processDirectory(Directory directory, {bool overwrite, int lineLength}) {
  print("Formatting directory ${directory.path}:");
  for (var entry in directory.listSync(recursive: true)) {
    if (!entry.path.endsWith(".dart")) continue;

    var relative = p.relative(entry.path, from: directory.path);
    processFile(
        entry, label: relative, overwrite: overwrite, lineLength: lineLength);
  }
}

/// Runs the formatter on [file].
void processFile(File file, {String label, bool overwrite, int lineLength}) {
  if (label == null) label = file.path;
  if (overwrite == null) overwrite = DEFAULT_OVERWRITE;
  if (lineLength == null) lineLength = DEFAULT_LINE_LENGTH;

  var formatter = new DartFormatter(pageWidth: lineLength);
  try {
    var output = formatter.format(file.readAsStringSync());
    if (overwrite) {
      file.writeAsStringSync(output);
      print("Formatted $label");
    } else {
      print(output);
    }
  } on FormatterException catch (err, stack) {
    stderr.writeln("Failed $label:\n$err");
  }
}
