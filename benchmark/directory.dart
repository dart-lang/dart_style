// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/profile.dart';

/// Reads a given directory of Dart files and repeatedly formats their contents.
///
/// This allows getting profile information on a large real-world codebase
/// while also factoring out the file IO time from the process.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run directory.dart <directory to format>');
    exit(65);
  }

  var directory = args[0];
  print('Listing entries in $directory...');
  var entries = Directory(directory).listSync(recursive: true);

  print('Reading sources...');
  var sources = <String>[];
  for (var entry in entries) {
    if (entry is File && entry.path.endsWith('.dart')) {
      Profile.count('File');
      sources.add(entry.readAsStringSync());
    }
  }

  for (var i = 0; i < 10; i++) {
    // Time with a separate stopwatch in case profiling is disabled.
    var watch = Stopwatch()..start();

    Profile.reset();
    Profile.begin('Whole enchilada');

    for (var i = 0; i < sources.length; i++) {
      stdout.write('\rFormatting ${i + 1}/${sources.length}...');
      _runFormatter(sources[i]);
    }

    Profile.end('Whole enchilada');

    var elapsed = watch.elapsedMilliseconds;

    print('');
    print('Total seconds ${elapsed / 1000}');
    Profile.report();
  }
}

void _runFormatter(String source) {
  try {
    var formatter = DartFormatter(experimentFlags: [tallStyleExperimentFlag]);

    var result = formatter.format(source);

    // Use the result to make sure the optimizer doesn't delete everything.
    if (result.length == 123) print('?');
  } on FormatterException catch (error) {
    print(error.message());
  }
}
