// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:args/args.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/debug.dart' as debug;
import 'package:dart_style/src/front_end/ast_node_visitor.dart';
import 'package:dart_style/src/profile.dart';
import 'package:dart_style/src/short/source_visitor.dart';
import 'package:dart_style/src/testing/benchmark.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;

/// The number of trials to run before measuring results.
const _warmUpTrials = 100;

/// The number of trials whose results are measured.
///
/// Should be an odd number so that we can grab the median easily.
const _measuredTrials = 51;

/// The number of times to format the benchmark in a single timed trial.
///
/// This is more than one because formatting small examples can be so fast that
/// it is dwarfed by noise and measuring overhead.
const _formatsPerTrial = 10;

/// Where to read and write the baseline file.
const _baselinePath = 'benchmark/baseline.json';

final _benchmarkDirectory = p.dirname(p.fromUri(Platform.script));

/// Whether to run a number of trials before measuring to warm up the JIT.
bool _runWarmupTrials = false;

/// Whether to use the short or tall style formatter.
bool _isShort = false;

/// If `true`, write the results to a baseline file for later comparison.
bool _writeBaseline = false;

/// If there is an existing baseline file, this contains the best time for each
/// named benchmark in the baseline file.
Map<String, double> _baseline = {};

Future<void> main(List<String> arguments) async {
  var benchmarks = await _parseArguments(arguments);

  // Don't read the baseline if this run is supposed to be creating a baseline.
  if (!_writeBaseline) {
    try {
      var baselineFile = File(_baselinePath);
      if (baselineFile.existsSync()) {
        var data =
            jsonDecode(baselineFile.readAsStringSync()) as Map<String, Object?>;
        data.forEach((name, metrics) {
          var fastest = (metrics as Map<String, Object?>)['fastest'] as double;
          _baseline[name] = fastest;
        });
      }
    } on IOException catch (error) {
      print('Failed to read baseline file "$_baselinePath".\n$error');
    }
  }

  if (_runWarmupTrials) _warmUp();

  var results = <(Benchmark, List<double>)>[];
  for (var benchmark in benchmarks) {
    var times = _runTrials('Benchmarking', benchmark, _measuredTrials);
    results.add((benchmark, times));
  }

  print('');
  var style = _isShort ? 'short' : 'tall';
  print('${"Benchmark ($style)".padRight(30)}  '
      'fastest   median  slowest  average  baseline');
  print('-----------------------------  '
      '--------  -------  -------  -------  --------');
  for (var (benchmark, measuredTimes) in results) {
    _printStats(benchmark.name, measuredTimes);
  }

  Profile.report();

  if (_writeBaseline) {
    var data = <String, Object?>{};
    for (var (benchmark, measuredTimes) in results) {
      data[benchmark.name] = {'fastest': measuredTimes.first};
    }

    var json = const JsonEncoder.withIndent('  ').convert(data);
    File(_baselinePath).writeAsStringSync(json);
    print('Wrote baseline to "$_baselinePath".');
  }
}

/// Run the large benchmark several times to warm up the JIT.
///
/// Since the benchmarks are run on the VM, JIT warm-up has a large impact on
/// performance. Warming up the VM gives it time for the optimized compiler to
/// kick in.
void _warmUp() {
  var benchmark = Benchmark.read('benchmark/case/large.unit');
  _runTrials('Warming up', benchmark, _warmUpTrials);
}

/// Runs [benchmark] [trials] times.
///
/// Returns the list of execution times sorted from shortest to longest.
List<double> _runTrials(String verb, Benchmark benchmark, int trials) {
  var source = SourceCode(benchmark.input);
  var expected = _isShort ? benchmark.shortOutput : benchmark.tallOutput;

  // Parse the source outside of the main benchmark loop. That way, analyzer
  // parse time (which we don't control) isn't part of the benchmark.
  var parseResult = parseString(
      content: source.text,
      featureSet: FeatureSet.fromEnableFlags2(
          sdkLanguageVersion: DartFormatter.latestLanguageVersion,
          flags: const []),
      path: source.uri,
      throwIfDiagnostics: false);

  var formatter = DartFormatter(
      languageVersion: _isShort
          ? DartFormatter.latestShortStyleLanguageVersion
          : DartFormatter.latestLanguageVersion,
      pageWidth: benchmark.pageWidth,
      lineEnding: '\n');

  var measuredTimes = <double>[];
  for (var i = 1; i <= trials; i++) {
    stdout.write('\r');
    stdout.write('$verb "${benchmark.name}" trial $i/$trials...');
    measuredTimes.add(_runTrial(formatter, parseResult, source, expected));
  }

  stdout.writeln();

  measuredTimes.sort();
  return measuredTimes;
}

double _runTrial(DartFormatter formatter, ParseStringResult parseResult,
    SourceCode source, String expected) {
  var stopwatch = Stopwatch()..start();

  // For a single benchmark, format the source multiple times.
  String? result;
  for (var j = 0; j < _formatsPerTrial; j++) {
    if (_isShort) {
      var visitor = SourceVisitor(formatter, parseResult.lineInfo, source);
      result = visitor.run(parseResult.unit).text;
    } else {
      var visitor = AstNodeVisitor(formatter, parseResult.lineInfo, source);
      result = visitor.run(source, parseResult.unit).text;
    }
  }

  var elapsed = stopwatch.elapsedMicroseconds / 1000 / _formatsPerTrial;

  // Sanity check to make sure the output is what we expect and to make sure
  // the VM doesn't optimize "dead" code away.
  if (result != expected) {
    print('Incorrect output:\n$result');
    exit(1);
  }

  return elapsed;
}

Future<List<Benchmark>> _parseArguments(List<String> arguments) async {
  var argParser = ArgParser();
  argParser.addFlag('help', negatable: false, help: 'Show usage information.');
  argParser.addFlag('aot',
      negatable: false,
      help: 'Whether the benchmark should run in AOT mode versus JIT.');
  argParser.addFlag('short',
      abbr: 's',
      negatable: false,
      help: 'Whether the formatter should use short or tall style.');
  argParser.addFlag('no-warmup',
      negatable: false, help: 'Skip the JIT warmup runs.');
  argParser.addFlag('write-baseline',
      abbr: 'w',
      negatable: false,
      help: 'Write the output as a baseline file for later comparison.');

  var argResults = argParser.parse(arguments);
  if (argResults['help'] as bool) {
    _usage(argParser, exitCode: 0);
  }

  if (argResults['aot'] as bool) {
    await rerunAsAot([
      for (var argument in arguments)
        if (argument != '--aot') argument,
      '--no-warmup',
    ]);
  }

  var benchmarks = switch (argResults.rest) {
    // Find all the benchmarks.
    ['all'] => Benchmark.findAll(await findPackageDirectory()),

    // Default to the large benchmark.
    [] => [Benchmark.read(p.join(_benchmarkDirectory, 'case/large.unit'))],

    // The user-specified list of paths.
    [...var paths] when paths.isNotEmpty => [
        for (var path in paths) Benchmark.read(path)
      ],
    _ => _usage(argParser, exitCode: 64),
  };

  _runWarmupTrials = !(argResults['no-warmup'] as bool);
  _isShort = argResults['short'] as bool;
  _writeBaseline = argResults['write-baseline'] as bool;

  return benchmarks;
}

void _printStats(String benchmark, List<double> times) {
  debug.useAnsiColors = true;

  var slowest = times.last;
  var fastest = times.first;
  var mean = times.reduce((a, b) => a + b) / _measuredTrials;
  var median = times[times.length ~/ 2];

  String number(double value) => value.toStringAsFixed(3).padLeft(7);

  var baseline = '  (none)';
  if (_baseline[benchmark] case var baseLineFastest?) {
    // Show the baseline's time as a percentage of the measured time. So:
    // -  50% means it took twice the time or half as hast.
    // - 100% means it took the same time as the baseline.
    // - 200% means it ran in half the time or twice as fast.
    var percent = baseLineFastest / fastest * 100;
    baseline = '${percent.toStringAsFixed(1).padLeft(7)}%';

    // If the difference is (probably) bigger than the noise, then show it in
    // color to make it clearer that smaller number is better.
    if (percent < 98) {
      baseline = debug.red(baseline);
    } else if (percent > 102) {
      baseline = debug.green(baseline);
    }
  }

  print('${benchmark.padRight(30)}  ${number(fastest)}  ${number(median)}'
      '  ${number(slowest)}  ${number(mean)}  $baseline');
}

/// Prints usage information.
///
/// If [exitCode] is non-zero, prints to stderr.
Never _usage(ArgParser argParser, {required int exitCode}) {
  var stream = exitCode == 0 ? stdout : stderr;

  stream.writeln('dart benchmark/run.dart [benchmark/case/<benchmark>.unit] '
      '[--aot] [--short] [--baseline=n]');
  stream.writeln('');
  stream.writeln(argParser.usage);

  exit(exitCode);
}
