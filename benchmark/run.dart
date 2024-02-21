// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:args/args.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/front_end/ast_node_visitor.dart';
import 'package:dart_style/src/source_visitor.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const _totalTrials = 100;
const _formatsPerTrial = 10;

final _benchmarkDirectory = p.dirname(p.fromUri(Platform.script));

void main(List<String> arguments) {
  var (:isShort, :baseline, :benchmarkPath) = _parseArguments(arguments);

  var sourceLines = File(benchmarkPath).readAsLinesSync();

  // The first line may have a "|" to indicate the page width.
  var pageWidth = 80;
  if (sourceLines[0].endsWith('|')) {
    pageWidth = sourceLines[0].indexOf('|');
    sourceLines.removeAt(0);
  }

  var sourceText = sourceLines.join('\n');
  var source = SourceCode(sourceText);

  var expected =
      File(p.setExtension(benchmarkPath, isShort ? '.expect_short' : '.expect'))
          .readAsStringSync();

  var benchmarkName = p.basenameWithoutExtension(benchmarkPath);

  print('Benchmarking "$benchmarkName" '
      'using ${isShort ? 'short' : 'tall'} style...');

  if (baseline != null) {
    print('Comparing to baseline where 100% = ${baseline.toStringAsFixed(3)}ms'
        ' (shorter is better)');
  }

  // Parse the source outside of the main benchmark loop. That way, analyzer
  // parse time (which we don't control) isn't part of the benchmark.
  var parseResult = parseString(
    content: source.text,
    featureSet: FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: Version(3, 3, 0), flags: const []),
    path: source.uri,
    throwIfDiagnostics: false,
  );

  var formatter = DartFormatter(
      pageWidth: pageWidth,
      lineEnding: '\n',
      experimentFlags: [if (!isShort) tallStyleExperimentFlag]);

  // Run the benchmark several times. This ensures the VM is warmed up and lets
  // us see how much variance there is.
  var best = 99999999.0;
  for (var i = 0; i <= _totalTrials; i++) {
    var stopwatch = Stopwatch()..start();

    // For a single benchmark, format the source multiple times.
    String? result;
    for (var j = 0; j < _formatsPerTrial; j++) {
      if (isShort) {
        var visitor = SourceVisitor(formatter, parseResult.lineInfo, source);
        result = visitor.run(parseResult.unit).text;
      } else {
        var visitor = AstNodeVisitor(formatter, parseResult.lineInfo, source);
        result = visitor.run(parseResult.unit).text;
      }
    }

    var elapsed = stopwatch.elapsedMicroseconds / 1000 / _formatsPerTrial;

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
    _printResult("Run ${'#$i'.padLeft(4)}", baseline, elapsed);
  }

  _printResult('Best    ', baseline, best);
}

({bool isShort, double? baseline, String benchmarkPath}) _parseArguments(
    List<String> arguments) {
  var argParser = ArgParser();
  argParser.addFlag('help', negatable: false, help: 'Show usage information.');
  argParser.addOption('baseline',
      abbr: 'b',
      help: 'The millisecond count of the baseline to compare the results to.');
  argParser.addFlag('short',
      abbr: 's',
      negatable: false,
      help: 'Whether the formatter should use short or tall style.');

  var argResults = argParser.parse(arguments);
  if (argResults['help'] as bool) {
    print('dart benchmark/run.dart benchmark/case/<benchmark>.unit '
        '[--short] [--baseline=n]');
    print('');
    print(argParser.usage);
    exit(0);
  }

  var benchmarkPath = '';
  switch (argResults.rest) {
    case []:
      // Default to the large benchmark.
      benchmarkPath = p.join(_benchmarkDirectory, 'case/large.unit');
    case [var path]:
      benchmarkPath = path;
    default:
      stderr.writeln('Usage: benchmark/run.dart [--short] <path to benchmark>');
      exit(64);
  }

  double? baseline;
  if (argResults.wasParsed('baseline')) {
    baseline = double.parse(argResults['baseline'] as String);
  }

  return (
    isShort: argResults['short'] as bool,
    baseline: baseline,
    benchmarkPath: benchmarkPath
  );
}

void _printResult(String label, double? baseline, double time) {
  if (baseline == null) {
    print('$label: ${time.toStringAsFixed(3).padLeft(7)}ms '
        "${'=' * ((time * 5).toInt())}");
  } else {
    var percent = 100 * time / baseline;
    print('$label: ${percent.toStringAsFixed(3).padLeft(7)}% '
        "${'=' * (percent ~/ 2)}");
  }
}
