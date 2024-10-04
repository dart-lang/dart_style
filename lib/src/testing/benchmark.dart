// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;

final class Benchmark {
  /// Finds all of the benchmarks in the `benchmark/cases` directory, relative
  /// to [packageDirectory].
  static List<Benchmark> findAll(String packageDirectory) {
    var casesDirectory = Directory(p.join(packageDirectory, 'benchmark/case'));

    var benchmarks = [
      for (var entry in casesDirectory.listSync())
        if (p.extension(entry.path) case '.unit' || '.stmt') read(entry.path)
    ];

    benchmarks.sort((a, b) => a.name.compareTo(b.name));

    return benchmarks;
  }

  /// Reads the benchmark from [path].
  ///
  /// This should point to a `.unit` or `.stmt` file that has a corresponding
  /// `.expect` and `expect_short` file in the same directory with those
  /// expectations.
  static Benchmark read(String path) {
    var inputLines = File(path).readAsLinesSync();

    // The first line may have a "|" to indicate the page width.
    var pageWidth = 80;
    if (inputLines[0].endsWith('|')) {
      pageWidth = inputLines[0].indexOf('|');
      inputLines.removeAt(0);
    }

    var input = inputLines.join('\n');

    var shortOutput =
        File(p.setExtension(path, '.expect_short')).readAsStringSync();
    var tallOutput = File(p.setExtension(path, '.expect')).readAsStringSync();

    return Benchmark(
        name: p.basenameWithoutExtension(path),
        input: input,
        pageWidth: pageWidth,
        isCompilationUnit: p.extension(path) == '.unit',
        shortOutput: shortOutput,
        tallOutput: tallOutput);
  }

  /// The short display name of the benchmark.
  final String name;

  /// The unformatted input.
  final String input;

  /// The page width that the input should be formatted at.
  final int pageWidth;

  /// Whether the benchmark's code is an entire compilation unit or a statement.
  final bool isCompilationUnit;

  /// The expected formatted output using short style.
  final String shortOutput;

  /// The expected formatted output using tall style.
  final String tallOutput;

  Benchmark(
      {required this.name,
      required this.input,
      required this.pageWidth,
      required this.isCompilationUnit,
      required this.shortOutput,
      required this.tallOutput});
}

/// Compiles the currently running script to an AOT snapshot and then executes
/// it.
///
/// This function never returns. When the AOT snapshot ends, this exits the
/// process.
Future<Never> rerunAsAot(List<String> arguments) async {
  var script = Platform.script.toFilePath();
  var snapshotPath = p.join(
      Directory.systemTemp.path, p.setExtension(p.basename(script), '.aot'));

  print('Creating AOT snapshot for $script...');
  var result = await Process.run(
      'dart', ['compile', 'aot-snapshot', '-o', snapshotPath, script]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('Failed to create AOT snapshot.');
    exit(result.exitCode);
  }

  print('Running AOT snapshot...');
  var process =
      await Process.start('dartaotruntime', [snapshotPath, ...arguments]);
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);

  var exitCode = await process.exitCode;

  await File(snapshotPath).delete();
  exit(exitCode);
}
