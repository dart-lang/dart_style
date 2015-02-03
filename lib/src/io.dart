// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.io;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
///
/// Returns `true` if successful or `false` if an error occurred in any of the
/// files.
bool processDirectory(Directory directory,
    {bool dryRun, bool overwrite, int pageWidth, bool followLinks: false}) {
  if (dryRun == null) dryRun = false;

  if (!dryRun) print("Formatting directory ${directory.path}:");

  var success = true;
  for (var entry in directory.listSync(
      recursive: true, followLinks: followLinks)) {
    var relative = p.relative(entry.path, from: directory.path);

    if (entry is Link) {
      if (!dryRun) print("Skipping link $relative");
      continue;
    }

    if (entry is! File || !entry.path.endsWith(".dart")) continue;

    // If the path is in a subdirectory starting with ".", ignore it.
    if (p.split(relative).any((part) => part.startsWith("."))) {
      if (!dryRun) print("Skipping hidden file $relative");
      continue;
    }

    if (!processFile(entry,
        label: relative,
        dryRun: dryRun,
        overwrite: overwrite,
        pageWidth: pageWidth)) {
      success = false;
    }
  }

  return success;
}

/// Runs the formatter on [file].
///
/// Returns `true` if successful or `false` if an error occurred.
bool processFile(File file,
    {String label, bool dryRun, bool overwrite, int pageWidth}) {
  if (label == null) label = file.path;
  if (dryRun == null) dryRun = false;
  if (overwrite == null) overwrite = false;

  var formatter = new DartFormatter(pageWidth: pageWidth);
  try {
    var source = file.readAsStringSync();
    var output = formatter.format(source, uri: file.path);
    if (dryRun) {
      // Only show the filenames of changed files.
      if (source != output) print(label);
    } else if (overwrite) {
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

    return true;
  } on FormatterException catch (err) {
    stderr.writeln(err.message());
  } catch (err, stack) {
    stderr.writeln('''Hit a bug in the formatter when formatting $label
  Please report at: github.com/dart-lang/dart_style/issues
$err
$stack''');
  }

  return false;
}
