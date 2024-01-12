// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
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

/// If tool/command_shell.dart has been compiled to a snapshot, this is the path
/// to it.
String? _commandExecutablePath;

/// If bin/format.dart has been compiled to a snapshot, this is the path to it.
String? _formatterExecutablePath;

/// Compiles format.dart to a native executable for tests to use.
///
/// Calls [setupAll()] and [tearDownAll()] to coordinate this when the
/// subsequent tests and to clean up the executable.
void compileFormatterExecutable() {
  setUpAll(() async {
    _formatterExecutablePath = await _compileSnapshot('bin/format.dart');
  });

  tearDownAll(() async {
    await _deleteSnapshot(_formatterExecutablePath!);
    _formatterExecutablePath = null;
  });
}

/// Compiles command_shell.dart to a native executable for tests to use.
///
/// Calls [setupAll()] and [tearDownAll()] to coordinate this when the
/// subsequent tests and to clean up the executable.
void compileCommandExecutable() {
  setUpAll(() async {
    _commandExecutablePath = await _compileSnapshot('tool/command_shell.dart');
  });

  tearDownAll(() async {
    await _deleteSnapshot(_commandExecutablePath!);
    _commandExecutablePath = null;
  });
}

/// Compile the Dart [script] to an app-JIT snapshot.
///
/// We do this instead of spawning the script from source each time because it's
/// much faster when the same script needs to be run several times.
Future<String> _compileSnapshot(String script) async {
  var scriptName = p.basename(script);
  var tempDir =
      await Directory.systemTemp.createTemp(p.withoutExtension(scriptName));
  var snapshot = p.join(tempDir.path, '$scriptName.snapshot');
  var scriptPath = p.normalize(p.join(await findTestDirectory(), '..', script));

  var compileResult = await Process.run(Platform.resolvedExecutable, [
    '--snapshot-kind=app-jit',
    '--snapshot=$snapshot',
    scriptPath,
    '--help'
  ]);

  if (compileResult.exitCode != 0) {
    fail('Could not compile $scriptName to a snapshot (exit code '
        '${compileResult.exitCode}):\n${compileResult.stdout}\n\n'
        '${compileResult.stderr}');
  }

  return snapshot;
}

/// Attempts to delete to temporary directory created for [snapshot] by
/// [_compileSnapshot()].
Future<void> _deleteSnapshot(String snapshot) async {
  try {
    await Directory(p.dirname(snapshot)).delete(recursive: true);
  } on IOException {
    // Do nothing if we failed to delete it. The OS will eventually clean it
    // up.
  }
}

/// Runs the command line formatter, passing it [args].
Future<TestProcess> runFormatter([List<String>? args]) {
  if (_formatterExecutablePath == null) {
    fail('Must call createFormatterExecutable() before running commands.');
  }

  return TestProcess.start(
      Platform.resolvedExecutable, [_formatterExecutablePath!, ...?args],
      workingDirectory: d.sandbox);
}

/// Runs the command line formatter, passing it the test directory followed by
/// [args].
Future<TestProcess> runFormatterOnDir([List<String>? args]) {
  return runFormatter(['.', ...?args]);
}

/// Runs the test shell for the [Command]-based formatter, passing it [args].
Future<TestProcess> runCommand([List<String>? args]) {
  if (_commandExecutablePath == null) {
    fail('Must call createCommandExecutable() before running commands.');
  }

  return TestProcess.start(Platform.resolvedExecutable,
      [_commandExecutablePath!, 'format', ...?args],
      workingDirectory: d.sandbox);
}

/// Runs the test shell for the [Command]-based formatter, passing it the test
/// directory followed by [args].
Future<TestProcess> runCommandOnDir([List<String>? args]) {
  return runCommand(['.', ...?args]);
}

/// Run tests defined in "*.unit" and "*.stmt" files inside directory [name].
Future<void> testDirectory(String name,
    {required bool tall, Iterable<StyleFix>? fixes}) async {
  for (var test in await TestFile.listDirectory(name)) {
    _testFile(test, tall, fixes);
  }
}

Future<void> testFile(String path,
    {required bool tall, Iterable<StyleFix>? fixes}) async {
  _testFile(await TestFile.read(path), tall, fixes);
}

void _testFile(
    TestFile testFile, bool useTallStyle, Iterable<StyleFix>? baseFixes) {
  group(testFile.path, () {
    for (var formatTest in testFile.tests) {
      test(formatTest.label, () {
        var formatter = DartFormatter(
            pageWidth: testFile.pageWidth,
            indent: formatTest.leadingIndent,
            fixes: [...?baseFixes, ...formatTest.fixes],
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
