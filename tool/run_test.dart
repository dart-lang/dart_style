// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_style/src/debug.dart' as debug;
import 'package:dart_style/src/testing/test_file.dart';

/// This script runs a single formatter test from a test file at a specific
/// line number.
///
/// This is helpful when debugging a specific test failure. It enables all
/// of the formatter's internal logging so you can see how it's making its
/// decisions.
void main(List<String> args) async {
  var parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage.')
    ..addFlag('trace-all', abbr: 't', help: 'Enable all debug tracing flags.')
    ..addFlag('trace-chunk-builder', help: 'Trace the chunk builder.')
    ..addFlag('trace-line-writer', help: 'Trace the line writer.')
    ..addFlag('trace-splitter', help: 'Trace the short style splitter.')
    ..addFlag('trace-piece-builder', help: 'Trace the piece builder.')
    ..addFlag('trace-indent', help: 'Trace indentation merging.')
    ..addFlag('trace-solver', help: 'Trace the piece solver.')
    ..addFlag(
      'trace-solver-enqueing',
      help: 'Trace the solver enqueuing solutions.',
    )
    ..addFlag(
      'trace-solver-dequeing',
      help: 'Trace the solver dequeuing solutions.',
    )
    ..addFlag('trace-solver-show-code', help: 'Trace the solver showing code.')
    ..addFlag('colors', defaultsTo: true, help: 'Use ANSI colors in output.');

  ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (exception) {
    print(exception.message);
    _printUsageAndExit(parser);
  }

  if (results['help'] as bool) _printUsageAndExit(parser, exitCode: 0);

  if (results.rest.length != 2) _printUsageAndExit(parser);

  var path = results.rest[0];
  if (path.startsWith('test/')) {
    path = path.substring(5);
  }

  var line = int.tryParse(results.rest[1]);
  if (line == null) {
    print('Line number must be an integer, was "${results.rest[1]}".');
    _printUsageAndExit(parser);
  }

  // Configure debug flags.
  var trace = results.flag('trace-all');
  void setFlag(String name, void Function(bool) setter) {
    setter(trace || results.flag(name));
  }

  setFlag('trace-chunk-builder', (v) => debug.traceChunkBuilder = v);
  setFlag('trace-line-writer', (v) => debug.traceLineWriter = v);
  setFlag('trace-splitter', (v) => debug.traceSplitter = v);
  setFlag('trace-piece-builder', (v) => debug.tracePieceBuilder = v);
  setFlag('trace-indent', (v) => debug.traceIndent = v);
  setFlag('trace-solver', (v) => debug.traceSolver = v);
  setFlag('trace-solver-enqueing', (v) => debug.traceSolverEnqueing = v);
  setFlag('trace-solver-dequeing', (v) => debug.traceSolverDequeing = v);
  setFlag('trace-solver-show-code', (v) => debug.traceSolverShowCode = v);

  debug.useAnsiColors = results.flag('colors');

  await _runTest(path, line);
}

Never _printUsageAndExit(ArgParser parser, {int exitCode = 64}) {
  print('''
Usage: dart tool/run_test.dart <path> <line> [flags...]

<path> The path to the test file, relative to the "test" directory or the
       package root directory.
<line> The 1-based line number where the test starts (the ">>>" line).

Exits with exit code 0 if the test passed and 1 if it failed.

Options:
${parser.usage}''');
  exit(exitCode);
}

/// Runs the formatter test starting on [line] at [path] inside the "test"
/// directory.
Future<void> _runTest(String path, int line) async {
  var testFile = await TestFile.read(path);
  var formatTest = testFile.tests.firstWhere(
    (test) => test.line == line,
    orElse: () {
      print('Could not find test at line $line in $path.');
      print('Available tests are:');
      for (var test in testFile.tests) {
        print('  ${test.line}: ${test.input.description}');
      }
      exit(1);
    },
  );

  var formatter = testFile.formatterForTest(formatTest);
  var actual = formatter.formatSource(formatTest.input.code);

  // Use the newest style for the expectation.
  var output = formatTest.outputs.values.last;

  var isCorrect =
      actual.textWithSelectionMarkers == output.code.textWithSelectionMarkers;

  print(
    [
      if (isCorrect) 'Correct' else 'Incorrect',
      'formatting for $path:$line',
      if (formatTest.input.description.isNotEmpty)
        '"${formatTest.input.description}"',
    ].join(' '),
  );
  print('');
  print('Input:');
  print(formatTest.input.code.textWithSelectionMarkers);
  print('');

  if (isCorrect) {
    print('Output:');
    _printOutput(actual.textWithSelectionMarkers, formatter.pageWidth);
    exit(0);
  } else {
    print('Expected:');
    _printOutput(output.code.textWithSelectionMarkers, formatter.pageWidth);
    print('');
    print('Actual:');
    _printOutput(actual.textWithSelectionMarkers, formatter.pageWidth);
    exit(1);
  }
}

/// Print formatter output with a vertical bar showing the [pageWidth].
void _printOutput(String output, int pageWidth) {
  for (var line in output.split('\n')) {
    if (line.length > pageWidth) {
      if (debug.useAnsiColors) {
        line =
            '${line.substring(0, pageWidth)}'
            '${debug.red(line.substring(pageWidth))}';
      }
      print(line);
    } else {
      var bar = debug.useAnsiColors ? debug.gray('|') : '|';
      print('${line.padRight(pageWidth)}$bar');
    }
  }
}
