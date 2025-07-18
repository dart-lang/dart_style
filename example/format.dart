// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/debug.dart' as debug;
import 'package:dart_style/src/testing/test_file.dart';
import 'package:pub_semver/pub_semver.dart';

void main(List<String> args) {
  // Enable debugging so you can see some of the formatter's internal state.
  // Normal users do not do this.
  debug.traceChunkBuilder = true;
  debug.traceLineWriter = true;
  debug.traceSplitter = true;
  debug.useAnsiColors = true;
  debug.tracePieceBuilder = true;
  debug.traceSolver = true;
  debug.traceSolverEnqueing = true;
  debug.traceSolverDequeing = true;
  debug.traceSolverShowCode = true;

  _formatStmt('''
  1 + 2;
  ''');

  _formatUnit('''
  class C {}
  ''');

  _runTest('other/selection.stmt', 2);
}

void _formatStmt(
  String source, {
  Version? version,
  int pageWidth = 40,
  TrailingCommas trailingCommas = TrailingCommas.automate,
}) {
  _runFormatter(
    source,
    pageWidth,
    version: version ?? DartFormatter.latestLanguageVersion,
    isCompilationUnit: false,
    trailingCommas: trailingCommas,
  );
}

void _formatUnit(
  String source, {
  Version? version,
  int pageWidth = 40,
  TrailingCommas trailingCommas = TrailingCommas.automate,
}) {
  _runFormatter(
    source,
    pageWidth,
    version: version ?? DartFormatter.latestLanguageVersion,
    isCompilationUnit: true,
    trailingCommas: trailingCommas,
  );
}

void _runFormatter(
  String source,
  int pageWidth, {
  required Version version,
  required bool isCompilationUnit,
  TrailingCommas trailingCommas = TrailingCommas.automate,
}) {
  try {
    var formatter = DartFormatter(
      languageVersion: version,
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
    );

    String result;
    if (isCompilationUnit) {
      result = formatter.format(source);
    } else {
      result = formatter.formatStatement(source);
    }

    _drawRuler('before', pageWidth);
    print(source);
    _drawRuler('after', pageWidth);
    print(result);
  } on FormatterException catch (error) {
    print(error.message());
  }
}

void _drawRuler(String label, int width) {
  var padding = ' ' * (width - label.length - 1);
  print('$label:$padding|');
}

/// Runs the formatter test starting on [line] at [path] inside the "test"
/// directory.
Future<void> _runTest(
  String path,
  int line, {
  int pageWidth = 40,
  bool tall = true,
}) async {
  var testFile = await TestFile.read('${tall ? 'tall' : 'short'}/$path');
  var formatTest = testFile.tests.firstWhere((test) => test.line == line);
  var formatter = testFile.formatterForTest(formatTest);

  var actual = formatter.formatSource(formatTest.input.code);

  // The test files always put a newline at the end of the expectation.
  // Statements from the formatter (correctly) don't have that, so add
  // one to line up with the expected result.
  var actualText = actual.textWithSelectionMarkers;
  if (!testFile.isCompilationUnit) actualText += '\n';

  var output = switch (formatTest) {
    UnversionedFormatTest(:var output) => output,
    // Used the newest style for the expectation.
    VersionedFormatTest(:var outputs) => outputs.values.last,
  };
  var expectedText = output.code.textWithSelectionMarkers;

  print('$path ${formatTest.input.description}');
  _drawRuler('before', pageWidth);
  print(formatTest.input.code.textWithSelectionMarkers);
  if (actualText == expectedText) {
    _drawRuler('result', pageWidth);
    print(actualText);
  } else {
    print('FAIL');
    _drawRuler('expected', pageWidth);
    print(expectedText);
    _drawRuler('actual', pageWidth);
    print(actualText);
  }
}
