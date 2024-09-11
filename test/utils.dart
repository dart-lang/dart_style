// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/testing/benchmark.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

const unformattedSource = 'void  main()  =>  print("hello") ;';
const formattedSource = 'void main() => print("hello");\n';

/// The same as formatted source but without a trailing newline because
/// [TestProcess] filters those when it strips command line output into lines.
const formattedOutput = 'void main() => print("hello");';

/// If `bin/format.dart` has been compiled to a snapshot, this is the path to
/// it.
String? _formatterPath;

/// Compiles `bin/format.dart` to a native executable for tests to use.
///
/// Calls [setupAll()] and [tearDownAll()] to coordinate this with the
/// subsequent tests and to clean up the executable.
void compileFormatter() {
  setUpAll(() async {
    var tempDir =
        await Directory.systemTemp.createTemp(p.withoutExtension('format'));
    _formatterPath = p.join(tempDir.path, 'format.dart.snapshot');
    var scriptPath =
        p.normalize(p.join(await findTestDirectory(), '../bin/format.dart'));

    var compileResult = await Process.run(Platform.resolvedExecutable, [
      '--snapshot-kind=app-jit',
      '--snapshot=$_formatterPath',
      scriptPath,
      '--help'
    ]);

    if (compileResult.exitCode != 0) {
      fail('Could not compile format.dart to a snapshot (exit code '
          '${compileResult.exitCode}):\n${compileResult.stdout}\n\n'
          '${compileResult.stderr}');
    }
  });

  tearDownAll(() async {
    try {
      await Directory(p.dirname(_formatterPath!)).delete(recursive: true);
    } on IOException {
      // Do nothing if we failed to delete it. The OS will eventually clean it
      // up.
    }
  });
}

/// Runs the command-line formatter, passing it [args].
Future<TestProcess> runFormatter([List<String>? args]) {
  if (_formatterPath == null) {
    fail('Must call createCommandExecutable() before running commands.');
  }

  return TestProcess.start(
      Platform.resolvedExecutable, [_formatterPath!, ...?args],
      workingDirectory: d.sandbox);
}

/// Runs the command-line formatter, passing it the test directory followed by
/// [args].
Future<TestProcess> runFormatterOnDir([List<String>? args]) {
  return runFormatter(['.', ...?args]);
}

/// Run tests defined in "*.unit" and "*.stmt" files inside directory [path].
Future<void> testDirectory(String path) async {
  for (var test in await TestFile.listDirectory(path)) {
    _testFile(test);
  }
}

Future<void> testFile(String path) async {
  _testFile(await TestFile.read(path));
}

/// Format all of the benchmarks and ensure they produce their expected outputs.
Future<void> testBenchmarks({required bool useTallStyle}) async {
  var benchmarks = Benchmark.findAll(await findPackageDirectory());

  group('Benchmarks', () {
    for (var benchmark in benchmarks) {
      test(benchmark.name, () {
        var formatter = DartFormatter(
            languageVersion: DartFormatter.latestLanguageVersion,
            pageWidth: benchmark.pageWidth,
            experimentFlags: useTallStyle
                ? const ['inline-class', 'macros', tallStyleExperimentFlag]
                : const ['inline-class', 'macros']);

        var actual = formatter.formatSource(SourceCode(benchmark.input));

        // The test files always put a newline at the end of the expectation.
        // Statements from the formatter (correctly) don't have that, so add
        // one to line up with the expected result.
        var actualText = actual.text;
        if (!benchmark.isCompilationUnit) actualText += '\n';

        var expected =
            useTallStyle ? benchmark.tallOutput : benchmark.shortOutput;

        // Fail with an explicit message because it's easier to read than
        // the matcher output.
        if (actualText != expected) {
          fail('Formatting did not match expectation. Expected:\n'
              '$expected\nActual:\n$actualText');
        }
      });
    }
  });
}

void _testFile(TestFile testFile) {
  var useTallStyle =
      testFile.path.startsWith('tall/') || testFile.path.startsWith('tall\\');

  group(testFile.path, () {
    for (var formatTest in testFile.tests) {
      test(formatTest.label, () {
        var formatter = DartFormatter(
            languageVersion: formatTest.languageVersion,
            pageWidth: testFile.pageWidth,
            indent: formatTest.leadingIndent,
            experimentFlags: useTallStyle
                ? const ['inline-class', 'macros', tallStyleExperimentFlag]
                : const ['inline-class', 'macros']);

        var actual = formatter.formatSource(formatTest.input);

        // The test files always put a newline at the end of the expectation.
        // Statements from the formatter (correctly) don't have that, so add
        // one to line up with the expected result.
        var actualText = actual.text;
        if (!testFile.isCompilationUnit) actualText += '\n';

        // Fail with an explicit message because it's easier to read than
        // the matcher output.
        if (actualText != formatTest.output.text) {
          fail('Formatting did not match expectation. Expected:\n'
              '${formatTest.output.text}\nActual:\n$actualText');
        } else if (actual.selectionStart != formatTest.output.selectionStart ||
            actual.selectionLength != formatTest.output.selectionLength) {
          fail('Selection did not match expectation. Expected:\n'
              '${formatTest.output.textWithSelectionMarkers}\n'
              'Actual:\n${actual.textWithSelectionMarkers}');
        }

        expect(actual.selectionStart, equals(formatTest.output.selectionStart));
        expect(
            actual.selectionLength, equals(formatTest.output.selectionLength));
      });
    }
  });
}

/// Create a test `.dart_tool` directory with a package config for a package
/// with [packageName] and language version [major].[minor].
d.DirectoryDescriptor packageConfig(String packageName, int major, int minor) {
  var config = '''
  {
    "configVersion": 2,
    "packages": [
      {
        "name": "$packageName",
        "rootUri": "../",
        "packageUri": "lib/",
        "languageVersion": "$major.$minor"
      }
    ]
  }''';

  return d.dir('.dart_tool', [d.file('package_config.json', config)]);
}
