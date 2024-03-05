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
import 'package:dart_style/src/testing/benchmark.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const _totalTrials = 100;
const _formatsPerTrial = 10;

final _benchmarkDirectory = p.dirname(p.fromUri(Platform.script));

Future<void> main(List<String> arguments) async {
  var (:isShort, :baseline, :benchmarks) = await _parseArguments(arguments);

  for (var benchmark in benchmarks) {
    _runBenchmark(benchmark, baseline, isShort: isShort);
  }
}

void _runBenchmark(Benchmark benchmark, double? baseline,
    {required bool isShort}) {
  var source = SourceCode(benchmark.input);
  var expected = isShort ? benchmark.shortOutput : benchmark.tallOutput;

  print('Benchmarking "${benchmark.name}" '
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
      pageWidth: benchmark.pageWidth,
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

Future<({bool isShort, double? baseline, List<Benchmark> benchmarks})>
    _parseArguments(List<String> arguments) async {
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
    _usage(argParser, exitCode: 0);
  }

  var benchmarks = switch (argResults.rest) {
    // Find all the benchmarks.
    ['all'] => await Benchmark.findAll(),

    // Default to the large benchmark.
    [] => [
        await Benchmark.read(p.join(_benchmarkDirectory, 'case/large.unit'))
      ],

    // The user-specified list of paths.
    [...var paths] when paths.isNotEmpty => [
        for (var path in paths) await Benchmark.read(path)
      ],
    _ => _usage(argParser, exitCode: 64),
  };

  double? baseline;
  if (argResults.wasParsed('baseline')) {
    baseline = double.parse(argResults['baseline'] as String);
  }

  return (
    isShort: argResults['short'] as bool,
    baseline: baseline,
    benchmarks: benchmarks
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

/// Prints usage information.
///
/// If [exitCode] is non-zero, prints to stderr.
Never _usage(ArgParser argParser, {required int exitCode}) {
  var stream = exitCode == 0 ? stdout : stderr;

  stream.writeln('dart benchmark/run.dart [benchmark/case/<benchmark>.unit] '
      '[--short] [--baseline=n]');
  stream.writeln('');
  stream.writeln(argParser.usage);

  exit(exitCode);
}
