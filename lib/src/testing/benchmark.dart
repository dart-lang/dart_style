// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'test_file.dart';

class Benchmark {
  /// Finds all of the benchmarks in the `benchmark/cases` directory.
  static Future<List<Benchmark>> findAll() async {
    var casesDirectory =
        Directory(p.join(await findPackageDirectory(), 'benchmark/case'));

    var benchmarks = [
      for (var entry in casesDirectory.listSync())
        if (p.extension(entry.path) case '.unit' || '.stmt')
          await read(entry.path)
    ];

    benchmarks.sort((a, b) => a.name.compareTo(b.name));

    return benchmarks;
  }

  /// Reads the benchmark from [path].
  ///
  /// This should point to a `.unit` or `.stmt` file that has a corresponding
  /// `.expect` and `expect_short` file in the same directory with those
  /// expectations.
  static Future<Benchmark> read(String path) async {
    var inputLines = await File(path).readAsLines();

    // The first line may have a "|" to indicate the page width.
    var pageWidth = 80;
    if (inputLines[0].endsWith('|')) {
      pageWidth = inputLines[0].indexOf('|');
      inputLines.removeAt(0);
    }

    var input = inputLines.join('\n');

    var shortOutput =
        await File(p.setExtension(path, '.expect_short')).readAsString();
    var tallOutput = await File(p.setExtension(path, '.expect')).readAsString();

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
