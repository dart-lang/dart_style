// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;

/// Update the formatting test expectations based on the current formatter's
/// output.
///
/// The command line arguments should be the names of tests to be updated. A
/// name can be a directory to update all of the tests in that directory or a
/// file path to update the tests in that file.
///
/// All paths are relative to the "test" directory.
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
    var path = p.join(await findTestDirectory(), argument);
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
    print('Skipped $_skippedFiles files '
        'which contain selections or Unicode escapes');
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

  // Write the file-level comments.
  _writeComments(buffer, testFile.comments);

  // TODO(rnystrom): This is duplicating logic in fix_test.dart. Ideally, we'd
  // move the fix markers into the tests themselves, but since --fix is
  // probably going away, it's not worth it.
  var baseFixes = const {
        'short/fixes/doc_comments.stmt': [StyleFix.docComments],
        'short/fixes/function_typedefs.unit': [StyleFix.functionTypedefs],
        'short/fixes/named_default_separator.unit': [
          StyleFix.namedDefaultSeparator
        ],
        'short/fixes/optional_const.unit': [StyleFix.optionalConst],
        'short/fixes/optional_new.stmt': [StyleFix.optionalNew],
        'short/fixes/single_cascade_statements.stmt': [
          StyleFix.singleCascadeStatements
        ],
      }[testFile.path] ??
      const <StyleFix>[];

  var experiments = [
    'inline-class',
    'macros',
    if (p.split(testFile.path).contains('tall')) tallStyleExperimentFlag
  ];

  _totalTests += testFile.tests.length;

  for (var formatTest in testFile.tests) {
    var formatter = DartFormatter(
        pageWidth: testFile.pageWidth,
        indent: formatTest.leadingIndent,
        fixes: [...baseFixes, ...formatTest.fixes],
        experimentFlags: experiments);

    var actual = formatter.formatSource(formatTest.input);

    // The test files always put a newline at the end of the expectation.
    // Statements from the formatter (correctly) don't have that, so add
    // one to line up with the expected result.
    var actualText = actual.text;
    if (!testFile.isCompilationUnit) actualText += '\n';

    // Insert a newline between each test, but not after the last.
    if (formatTest != testFile.tests.first) buffer.writeln();

    var descriptionParts = [
      if (formatTest.leadingIndent != 0) '(indent ${formatTest.leadingIndent})',
      for (var fix in formatTest.fixes) '(fix ${fix.name})',
      formatTest.description
    ];

    buffer.writeln('>>> ${descriptionParts.join(' ')}'.trim());
    _writeComments(buffer, formatTest.inputComments);
    buffer.write(formatTest.input.text);

    buffer.writeln('<<< ${formatTest.outputDescription}'.trim());
    _writeComments(buffer, formatTest.outputComments);

    var output = actual.text;

    // Remove the trailing newline so that we don't end up with an extra
    // newline at the end of the test file.
    output = output.trimRight();
    buffer.write(output);

    // Fail with an explicit message because it's easier to read than
    // the matcher output.
    if (actualText != formatTest.output.text) {
      print('Updated ${testFile.path} ${formatTest.label}');
      _changedTests++;
    }
  }

  // Rewrite the file. Do this even if nothing changed so that we normalize the
  // test markers.
  var path = p.join(await findTestDirectory(), testFile.path);
  File(path).writeAsStringSync(buffer.toString());
}

void _writeComments(StringBuffer buffer, List<String> comments) {
  for (var comment in comments) {
    buffer.writeln(comment);
  }
}
