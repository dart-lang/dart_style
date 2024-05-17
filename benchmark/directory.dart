// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:collection/collection.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/profile.dart';
import 'package:dart_style/src/testing/benchmark.dart';

/// Whether to use the short or tall style formatter.
bool _isShort = false;

/// Reads a given directory of Dart files and repeatedly formats their contents.
///
/// This allows getting profile information on a large real-world codebase
/// while also factoring out the file IO time from the process.
void main(List<String> arguments) async {
  var directory = await _parseArguments(arguments);

  print('Listing entries in $directory...');
  var entries = Directory(directory).listSync(recursive: true);

  // Make sure the benchmark is deterministic. The order shouldn't really
  // matter for performance, but since the JIT is warming up as it goes through
  // the files, different orders could potentially affect how it chooses to
  // optimize.
  entries.sortBy((entry) => entry.path);

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
    var formatter = DartFormatter(
        experimentFlags: [if (!_isShort) tallStyleExperimentFlag]);

    var result = formatter.format(source);

    // Use the result to make sure the optimizer doesn't delete everything.
    if (result.length == 123) print('?');
  } on FormatterException catch (error) {
    print(error.message());
  }
}

/// Parses the command line arguments and options.
///
/// Returns the path to the directory that should be formatted.
Future<String> _parseArguments(List<String> arguments) async {
  var argParser = ArgParser();
  argParser.addFlag('help', negatable: false, help: 'Show usage information.');
  argParser.addFlag('short',
      abbr: 's',
      negatable: false,
      help: 'Whether the formatter should use short or tall style.');
  argParser.addFlag('aot',
      negatable: false,
      help: 'Whether the benchmark should run in AOT mode versus JIT.');

  var argResults = argParser.parse(arguments);
  if (argResults['help'] as bool) {
    _usage(argParser, exitCode: 0);
  }

  if (argResults.rest.length != 1) {
    stderr.writeln('Missing directory path to format.');
    stderr.writeln();
    _usage(argParser, exitCode: 0);
  }

  if (argResults['aot'] as bool) {
    await rerunAsAot([
      for (var argument in arguments)
        if (argument != '--aot') argument,
    ]);
  }

  _isShort = argResults['short'] as bool;

  return argResults.rest.single;
}

/// Prints usage information.
///
/// If [exitCode] is non-zero, prints to stderr.
Never _usage(ArgParser argParser, {required int exitCode}) {
  var stream = exitCode == 0 ? stdout : stderr;

  stream.writeln('dart benchmark/directory.dart [--aot] <directory>');
  stream.writeln('');
  stream.writeln(argParser.usage);

  exit(exitCode);
}
