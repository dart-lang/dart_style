// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;

/// Update the formatting test expectations based on the current formatter's
/// output.
///
/// The command line arguments should be the names of tests to be updated. A
/// name can be a directory to update all of the tests in that directory or a
/// file path to update the tests in that file.
///
/// All paths are relative to the package root directory.
///
/// Note: This script can't correctly update any tests that contain the special
/// "×XX" Unicode markers or selections.
// TODO(rnystrom): Support updating individual tests within a file.
void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    print('Usage: update_tests.dart <tests...>');
    exit(1);
  }

  for (var argument in arguments) {
    var path = p.join(await findPackageDirectory(), argument);
    if (Directory(path).existsSync()) {
      await _updateDirectory(path);
    } else if (File(path).existsSync()) {
      await _updateFile(path);
    }
  }

  if (_totalTests > 0) {
    print('Changed $_changedTests out of $_totalTests updated tests');
  } else {
    print('No updatable tests found');
  }

  if (_skippedFiles > 0) {
    print(
      'Skipped $_skippedFiles files '
      'which contain selections or Unicode escapes',
    );
  }
}

int _totalTests = 0;
int _changedTests = 0;
int _skippedFiles = 0;

Future<void> _updateDirectory(String path) async {
  for (var testFile in await TestFile.listDirectory(path)) {
    await _updateTestFile(testFile);
  }
}

Future<void> _updateFile(String path) async {
  await _updateTestFile(await TestFile.read(path));
}

Future<void> _updateTestFile(TestFile testFile) async {
  // TODO(rnystrom): The test updater doesn't know how to handle selection
  // markers or Unicode escapes in tests, so just skip any file that contains
  // tests with those in it.
  var testSource = File(p.join('test', testFile.path)).readAsStringSync();
  if (testSource.contains('‹') || testSource.contains('×')) {
    print('Skipped ${testFile.path}');

    _skippedFiles++;
    return;
  }

  var buffer = StringBuffer();

  // Write the page width line if needed.
  var pageWidth = testFile.pageWidth;
  if (pageWidth != null) {
    var columns = '$pageWidth columns';
    buffer.write(columns);
    buffer.write(' ' * (pageWidth - columns.length));
    buffer.writeln('|');
  }

  // Write the file level options.
  if (_optionStrings(testFile.options) case var options
      when options.isNotEmpty) {
    buffer.writeln(options.join(' '));
  }

  // Write the file-level comments.
  _writeComments(buffer, testFile.comments);

  _totalTests += testFile.tests.length;

  // Write the tests.
  for (var formatTest in testFile.tests) {
    var defaultVersion =
        testFile.isTall
            ? DartFormatter.latestLanguageVersion
            : DartFormatter.latestShortStyleLanguageVersion;

    // Write the test input.
    var description = [
      ..._optionStrings(formatTest.options),
      formatTest.input.description,
    ].join(' ');

    buffer.writeln('>>> $description'.trim());
    _writeComments(buffer, formatTest.input.comments);
    buffer.write(formatTest.input.code.text);

    // Write the test outputs.
    var changed = false;
    for (var output in formatTest.outputs) {
      var outputDescription = [
        // Include the version in the description if the output has one.
        if (output.version case var version?)
          '${version.major}.${version.minor}',
        output.description,
      ].join(' ');

      buffer.writeln('<<< $outputDescription'.trim());
      _writeComments(buffer, output.comments);

      var formatter = testFile.formatterForTest(
        formatTest,
        output.version ?? defaultVersion,
      );

      var actual = formatter.formatSource(formatTest.input.code);

      buffer.write(actual.text);

      // When formatting a statement, the formatter correctly doesn't add a
      // trailing newline, but we need one to separate this output from the
      // next test.
      if (!testFile.isCompilationUnit) buffer.writeln();

      if (actual.text != output.code.text) changed = true;
    }

    if (changed) {
      print('Updated ${testFile.path} ${formatTest.label}');
      _changedTests++;
    }
  }

  // Rewrite the file. Do this even if nothing changed so that we normalize the
  // test markers.
  var path = p.join(await findTestDirectory(), testFile.path);
  File(path).writeAsStringSync(buffer.toString());
}

/// Returns a list of strings for all of the options specified by [options].
List<String> _optionStrings(TestOptions options) => [
  for (var experiment in options.experimentFlags) '(experiment $experiment)',
  if (options.leadingIndent case var indent?) '(indent $indent)',
  if (options.trailingCommas == TrailingCommas.preserve)
    '(trailing_commas preserve)',
];

void _writeComments(StringBuffer buffer, List<String> comments) {
  for (var comment in comments) {
    buffer.writeln(comment);
  }
}
