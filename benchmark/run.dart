// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:path/path.dart' as p;

const _totalTrials = 100;
const _formatsPerTrial = 10;

final _benchmarkDirectory = p.dirname(p.fromUri(Platform.script));

void main(List<String> args) {
  args = args.toList();
  var isShort = args.remove('--short');

  var benchmarkPath = '';
  switch (args) {
    case []:
      // Default to the large benchmark.
      benchmarkPath = p.join(_benchmarkDirectory, 'case/large.unit');
    case [var path]:
      benchmarkPath = path;
    default:
      stderr.writeln('Usage: benchmark/run.dart [--short] <path to benchmark>');
      exit(64);
  }

  var sourceLines = File(benchmarkPath).readAsLinesSync();

  // The first line may have a "|" to indicate the page width.
  var pageWidth = 80;
  if (sourceLines[0].endsWith('|')) {
    pageWidth = sourceLines[0].indexOf('|');
    sourceLines.removeAt(0);
  }

  var source = sourceLines.join('\n');

  var expected =
      File(p.setExtension(benchmarkPath, isShort ? '.expect_short' : '.expect'))
          .readAsStringSync();

  var benchmarkName = p.basenameWithoutExtension(benchmarkPath);
  var formatter = DartFormatter(
      pageWidth: pageWidth,
      experimentFlags: [if (!isShort) tallStyleExperimentFlag]);
  var isStatement = benchmarkPath.endsWith('.stmt');

  print('Benchmarking "$benchmarkName" '
      'using ${isShort ? 'short' : 'tall'} style...');

  // Run the benchmark several times. This ensures the VM is warmed up and lets
  // us see how much variance there is.
  var best = 99999999.0;
  for (var i = 0; i <= _totalTrials; i++) {
    var stopwatch = Stopwatch()..start();

    // For a single benchmark, format the source multiple times.
    String? result;
    for (var j = 0; j < _formatsPerTrial; j++) {
      if (isStatement) {
        result = formatter.formatStatement(source);
      } else {
        result = formatter.format(source);
      }
    }

    var elapsed = stopwatch.elapsedMilliseconds / _formatsPerTrial;

    // Keep track of the best run so far.
    if (elapsed >= best) continue;
    best = elapsed;

    // Sanity check to make sure the output is what we expect and to make sure
    // the VM doesn't optimize "dead" code away.
    if (result != expected) {
      print('Incorrect output:\n$result');
      exit(1);
    }

    // Don't print the first run. It's always terrible since the VM hasn't
    // warmed up yet.
    if (i == 0) continue;
    _printResult("Run ${'#$i'.padLeft(4)}", elapsed);
  }

  _printResult('Best    ', best);
}

void _printResult(String label, double time) {
  print('$label: ${time.toStringAsFixed(2).padLeft(6)}ms '
      "${'=' * ((time * 5).toInt())}");
}
