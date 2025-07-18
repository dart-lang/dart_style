// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/testing/benchmark.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
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

/// All of the supported tall style versions that we run the tests against.
final List<Version> _testedTallVersions = [
  for (
    var version = DartFormatter.latestShortStyleLanguageVersion.nextMinor;
    version <= DartFormatter.latestLanguageVersion;
    version = version.nextMinor
  )
    version,
];

/// Compiles `bin/format.dart` to a native executable for tests to use.
///
/// Calls [setupAll()] and [tearDownAll()] to coordinate this with the
/// subsequent tests and to clean up the executable.
void compileFormatter() {
  setUpAll(() async {
    var tempDir = await Directory.systemTemp.createTemp(
      p.withoutExtension('format'),
    );
    _formatterPath = p.join(tempDir.path, 'format.dart.snapshot');
    var scriptPath = p.normalize(
      p.join(await findTestDirectory(), '../bin/format.dart'),
    );

    var compileResult = await Process.run(Platform.resolvedExecutable, [
      '--snapshot-kind=app-jit',
      '--snapshot=$_formatterPath',
      scriptPath,
      '--help',
    ]);

    if (compileResult.exitCode != 0) {
      fail(
        'Could not compile format.dart to a snapshot (exit code '
        '${compileResult.exitCode}):\n${compileResult.stdout}\n\n'
        '${compileResult.stderr}',
      );
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

  return TestProcess.start(Platform.resolvedExecutable, [
    _formatterPath!,
    ...?args,
  ], workingDirectory: d.sandbox);
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
          languageVersion:
              useTallStyle
                  ? DartFormatter.latestLanguageVersion
                  : DartFormatter.latestShortStyleLanguageVersion,
          pageWidth: benchmark.pageWidth,
        );

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
          fail(
            'Formatting did not match expectation. Expected:\n'
            '$expected\nActual:\n$actualText',
          );
        }
      });
    }
  });
}

void _testFile(TestFile testFile) {
  group(testFile.path, () {
    for (var formatTest in testFile.tests) {
      Map<Version, TestEntry> testedVersions;
      if (testFile.isTall) {
        testedVersions = switch (formatTest) {
          // This output is unversioned, so test at the lowest and highest
          // supported versions. If it formats the same on those, we assume
          // it does for all of the intermediate versions too.
          UnversionedFormatTest(:var output) => {
            _testedTallVersions.first: output,
            _testedTallVersions.last: output,
          },
          VersionedFormatTest(:var outputs) => _versionedTestEntries(outputs),
        };
      } else {
        testedVersions = switch (formatTest) {
          UnversionedFormatTest(:var output) => {
            DartFormatter.latestShortStyleLanguageVersion: output,
          },
          // There is only one versioned short style test, for the legacy
          // switch syntax. If the test is versioned, only run it on those
          // versions and not anything later.
          VersionedFormatTest(:var outputs) => outputs,
        };
      }

      testedVersions.forEach((version, output) {
        _runTestAtVersion(testFile, formatTest, output, version);
      });
    }
  });
}

/// Given a set of versions that have specific test expectations, determine
/// what set of versions should be tested against which outputs.
///
/// Ideally, we'd test every supported language version against an appropriate
/// output. But that means that every time a new Dart SDK comes out and the
/// supported version range grows, the set of tests being run increases
/// significantly.
///
/// To avoid that, we conservatively assume that if a test formats the same way
/// at two versions that have the same expected output, then it would format
/// the same way at any version between them. Thus, whenever there is a range
/// of versions that should all produce the same output, we only test the
/// endpoints of the range.
///
/// For example, say the supported versions are:
///
///     3.7  3.8  3.9  3.10  3.11  3.12  3.13  3.14  3.15
///
/// And say that a test has specified outputs like:
///
///     <<<
///     ...
///     >>> 3.8 first supported version
///     A
///     >>> 3.11 style tweak
///     B
///     >>> 3.13 another style tweak
///     C
///
/// The test is stating that formatting at each version should produce these
/// outputs:
///
///     3.7  3.8  3.9  3.10  3.11  3.12  3.13  3.14  3.15
///          A    A    A     B     C     C     C     C
///
/// We run the tests at these versions:
///
///     3.7  3.8  3.9  3.10  3.11  3.12  3.13  3.14  3.15
///          A         A     B     C                 C
///
/// We skip 3.7 because it's below the lowest supported version. (Presumably
/// this test is for some syntax added in 3.8.) We skip 3.9, 3.13, and 3.14
/// because they are in the middle of a range of supported versions that all
/// expect the same output.
Map<Version, TestEntry> _versionedTestEntries(Map<Version, TestEntry> outputs) {
  var outputVersions = outputs.keys.toList()..sort();
  var testedVersions = <Version, TestEntry>{};

  // For each output, test the language version at each end of the range it
  // covers.
  for (var i = 0; i < outputVersions.length; i++) {
    // The output specifies the low end of its range.
    var version = outputVersions[i];
    testedVersions[version] = outputs[version]!;

    // Find the high end of the range.
    if (i < outputVersions.length - 1) {
      // The end of this version's range is one version lower than the next
      // output's version.
      var nextVersionIndex = _testedTallVersions.indexOf(outputVersions[i + 1]);
      var rangeEnd = _testedTallVersions[nextVersionIndex - 1];
      testedVersions[rangeEnd] = outputs[version]!;
    } else {
      // The end of this version's range is the highest supported version.
      testedVersions[_testedTallVersions.last] = outputs[version]!;
    }
  }

  return testedVersions;
}

void _runTestAtVersion(
  TestFile testFile,
  FormatTest formatTest,
  TestEntry output,
  Version version,
) {
  var description =
      'line ${formatTest.line} at ${version.major}.${version.minor}';
  if (formatTest.input.description.isNotEmpty) {
    description += ': ${formatTest.input.description}';
  }

  test(description, () {
    var formatter = testFile.formatterForTest(formatTest, version);

    var actual = _validateFormat(
      formatter,
      formatTest.input.code,
      output.code,
      'did not match expectation',
      testFile.isCompilationUnit,
    );

    // Make sure that formatting is idempotent. Format the output and make
    // sure we get the same result.
    _validateFormat(
      formatter,
      actual,
      actual,
      'was not idempotent',
      testFile.isCompilationUnit,
    );
  });
}

/// Run [formatter] on [input] and validate that the result matches [expected].
///
/// If not, fails with an error using [reason].
///
/// Returns the formatted output.
SourceCode _validateFormat(
  DartFormatter formatter,
  SourceCode input,
  SourceCode expected,
  String reason,
  bool isCompilationUnit,
) {
  var actual = formatter.formatSource(input);

  // Fail with an explicit message because it's easier to read than
  // the matcher output.
  if (actual.text != expected.text) {
    fail(
      'Formatting $reason. Expected:\n'
      '${expected.text}\nActual:\n${actual.text}',
    );
  } else if (actual.selectionStart != expected.selectionStart ||
      actual.selectionLength != expected.selectionLength) {
    fail(
      'Selection $reason. Expected:\n'
      '${expected.textWithSelectionMarkers}\n'
      'Actual:\n${actual.textWithSelectionMarkers}',
    );
  }

  return actual;
}

/// Create a test `.dart_tool` directory with a package config for a package
/// with [rootPackageName] and language version [major].[minor].
///
/// If [packages] is given, it should be a map from package names to root URIs
/// for each package.
d.DirectoryDescriptor packageConfig(
  String rootPackageName, {
  String? version,
  Map<String, String>? packages,
}) {
  var defaultVersion = DartFormatter.latestLanguageVersion;
  version ??= '${defaultVersion.major}.${defaultVersion.minor}';

  Map<String, dynamic> package(String name, String rootUri) => {
    'name': name,
    'rootUri': rootUri,
    'packageUri': 'lib/',
    'languageVersion': version,
  };

  var config = {
    'configVersion': 2,
    'packages': [
      package(rootPackageName, '../'),
      if (packages != null)
        for (var name in packages.keys) package(name, packages[name]!),
    ],
  };

  return d.dir('.dart_tool', [
    d.file('package_config.json', jsonEncode(config)),
  ]);
}

/// Creates the YAML string contents of an analysis options file.
///
/// If [pageWidth] is given, then the result has a "formatter" section to
/// specify the page width. If [trailingCommas] is given, then the result has a
/// "formatter" section specifying the trailing commas mode. If [include] is
/// given, then adds an "include" key to include another analysis options file.
/// If [other] is given, then those are added as other top-level keys in the
/// YAML.
String analysisOptions({
  int? pageWidth,
  TrailingCommas? trailingCommas,
  Object? /* String | List<String> */ include,
  Map<String, Object>? other,
}) {
  var yaml = StringBuffer();

  switch (include) {
    case String _:
      yaml.writeln('include: $include');
    case List<String> _:
      yaml.writeln('include:');
      for (var path in include) {
        yaml.writeln('  - $path');
      }
  }

  if (pageWidth != null || trailingCommas != null) {
    yaml.writeln('formatter:');
    if (pageWidth != null) {
      yaml.writeln('  page_width: $pageWidth');
    }

    if (trailingCommas != null) {
      yaml.writeln('  trailing_commas: ${trailingCommas.name}');
    }
  }

  if (other != null) {
    other.forEach((key, value) {
      yaml.writeln('$key:');
      yaml.writeln('  $value');
    });
  }

  return yaml.toString();
}

/// Creates a file named "analysis_options.yaml" containing the given YAML
/// options to configure the [pageWidth] and [include] file, if any.
d.FileDescriptor analysisOptionsFile({
  String name = 'analysis_options.yaml',
  int? pageWidth,
  TrailingCommas? trailingCommas,
  String? include,
}) {
  var yaml = analysisOptions(
    pageWidth: pageWidth,
    trailingCommas: trailingCommas,
    include: include,
  );
  return d.FileDescriptor(name, yaml.toString());
}
