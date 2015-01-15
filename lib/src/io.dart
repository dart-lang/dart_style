// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.io;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
void processDirectory(Directory directory,
    {bool overwrite, int pageWidth, bool followLinks: false}) {
  print("Formatting directory ${directory.path}:");
  for (var entry in directory.listSync(
      recursive: true, followLinks: followLinks)) {
    var relative = p.relative(entry.path, from: directory.path);

    if (entry is Link) {
      print("Skipping link $relative");
      continue;
    }

    if (entry is! File || !entry.path.endsWith(".dart")) continue;

    // If the path is in a subdirectory starting with ".", ignore it.
    if (p.split(relative).any((part) => part.startsWith("."))) {
      print("Skipping hidden file $relative");
      continue;
    }

    processFile(
        entry, label: relative, overwrite: overwrite, pageWidth: pageWidth);
  }
}

/// Runs the formatter on [file].
void processFile(File file, {String label, bool overwrite, int pageWidth}) {
  if (label == null) label = file.path;
  if (overwrite == null) overwrite = false;

  var formatter = new DartFormatter(pageWidth: pageWidth);
  try {
    var source = file.readAsStringSync();
    var output = formatter.format(source, uri: file.path);
    if (overwrite) {
      if (source != output) {
        file.writeAsStringSync(output);
        print("Formatted $label");
      } else {
        print("Unchanged $label");
      }
    } else {
      // Don't add an extra newline.
      stdout.write(output);
    }
  } on FormatterException catch (err) {
    stderr.writeln(err.message());
  } catch (err, stack) {
    stderr.writeln('''Hit a bug in the formatter when formatting $label
  Please report at: github.com/dart-lang/dart_style/issues
$err
$stack''');
  }
}
