// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/dart_version_history.dart';
import 'package:dart_style/src/testing/test_file.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

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
    _updateTest(buffer, testFile, formatTest);
  }

  // Rewrite the file. Do this even if nothing changed so that we normalize the
  // test markers.
  var path = p.join(await findTestDirectory(), testFile.path);
  File(path).writeAsStringSync(buffer.toString());
}

void _updateTest(
  StringBuffer buffer,
  TestFile testFile,
  FormatTest formatTest,
) {
  // Write the test input.
  var description = [
    ..._optionStrings(formatTest.options),
    formatTest.input.description,
  ].join(' ');

  buffer.writeln('>>> $description'.trim());
  _writeComments(buffer, formatTest.input.comments);
  buffer.write(formatTest.input.code.text);

  // Run the formatter for every version and group versions that produce the
  // same output together.
  var versionsToTest = _versionsToTest(testFile, formatTest);
  var distinctOutputs = <(Version, String)>[];
  String? previousVersionOutput;
  for (var version in versionsToTest) {
    var formatter = testFile.formatterForTest(formatTest, version);
    var output = formatter.formatSource(formatTest.input.code).text;
    if (output != previousVersionOutput) {
      distinctOutputs.add((version, output));
      previousVersionOutput = output;
    }
  }

  // Write the test outputs.
  var changed = false;
  for (var (version, output) in distinctOutputs) {
    // The tests used to not be versioned or have any version markers. To
    // minimize the diffs when support for versioned sections was added, we
    // didn't write them for short tests (which generally aren't versioned) or
    // for tall tests that didn't need them.
    // TODO(rnystrom): It would be simpler and more explicit in the test to
    // always write a version.
    Version? shownVersion;
    if (testFile.isTall &&
        (distinctOutputs.length != 1 ||
            version != DartVersionHistory.earliestTallStyle)) {
      shownVersion = version;
    }

    changed |= _writeOutputSection(
      buffer,
      testFile,
      formatTest,
      shownVersion,
      output,
    );
  }

  if (formatTest.unsupportedVersion case var version?) {
    buffer.writeln('<<< ${version.majorMinor} (unsupported)');
  }

  if (changed) {
    print('Updated ${testFile.path} ${formatTest.label}');
    _changedTests++;
  }
}

/// Determine which range of language versions should be used for [formatTest].
List<Version> _versionsToTest(TestFile testFile, FormatTest formatTest) {
  // If the test already has an unsupported marker, then we assume the test
  // author knows the tested syntax isn't supported on later language versions
  // so stop there.
  var endVersion = switch (formatTest.unsupportedVersion) {
    var unsupported? => DartVersionHistory.before(unsupported),
    _ when testFile.isTall => DartVersionHistory.latest,
    _ => DartVersionHistory.latestShortStyle,
  };

  // If the test already has a section that starts with a given version, then
  // we assume the test author knows the tested syntax isn't supported on older
  // versions, so start there.
  var startVersion = switch (formatTest) {
    // Outputs are required to be in version order already.
    VersionedFormatTest(:var outputs) => outputs.keys.first,

    // Cover the whole range of tall versions.
    _ when testFile.isTall => DartVersionHistory.earliestTallStyle,

    // Short tests aren't versioned, so just pick the one version. This is
    // usually [DartVersionHistory.latestShortStyle], but will be 2.19 for the
    // old switch syntax test.
    _ => endVersion,
  };

  return DartVersionHistory.all
      .where((v) => v >= startVersion && v <= endVersion)
      .toList();
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

/// Formats [formatTest] as [version] and writes the resulting output to
/// [buffer].
///
/// Returns `true` if the output changed from what was previously in the file.
bool _writeOutputSection(
  StringBuffer buffer,
  TestFile testFile,
  FormatTest formatTest,
  Version? version,
  String actualText,
) {
  // Preserve the description and comments from the existing output section if
  // there is one.
  var originalEntry = switch (formatTest) {
    UnversionedFormatTest() when version == null => formatTest.output,
    UnversionedFormatTest()
        when version == DartVersionHistory.earliestTallStyle =>
      formatTest.output,

    // If we're splitting an unversioned tall test, the first section (at 3.7)
    // should use the original unversioned entry's description/comments.
    VersionedFormatTest(:var outputs) => outputs[version],
    _ => null,
  };

  var description = originalEntry?.description ?? '';
  var outputDescription = [
    if (version != null) version.majorMinor,
    description,
  ].join(' ').trim();

  buffer.writeln('<<< $outputDescription'.trim());
  if (originalEntry != null) _writeComments(buffer, originalEntry.comments);

  buffer.write(actualText);

  // When formatting a statement, the formatter correctly doesn't add a
  // trailing newline, but we need one to separate this output from the
  // next test.
  if (!testFile.isCompilationUnit) buffer.writeln();

  return originalEntry == null || actualText != originalEntry.code.text;
}
