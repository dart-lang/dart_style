// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/constants.dart';
import 'package:dart_style/src/debug.dart' as debug;
import 'package:dart_style/src/testing/test_file.dart';

void main(List<String> args) {
  // Enable debugging so you can see some of the formatter's internal state.
  // Normal users do not do this.
  debug.traceChunkBuilder = true;
  debug.traceLineWriter = true;
  debug.traceSplitter = true;
  debug.useAnsiColors = true;
  debug.tracePieceBuilder = true;
  // debug.traceSolverEnqueueing = true;
  debug.traceSolver = true;
  debug.traceConstraints = true;

//   _formatStmt('''
// function() =>
//     another(
//       argument,
//       anotherArgument,
//     ).property.method(argument);
//   ''');

//   _formatStmt('''
// {
//   var first = expression +
//       anotherOperand +
//       aThirdOperand;
//   var [
//     element1,
//     element2,
//     element3,
//     element4,
//   ] = expression +
//       anotherOperand +
//       aThirdOperand;
// }
// ''');

//   _formatStmt('''
// var result = target
//     .someMethod1(argument1, argument2, argument3)
//     .someMethod2(argument1, argument2, argument3)
//     .someMethod3(argument1, argument2, argument3)
//     .someMethod4(argument1, argument2, argument3)
//     .someMethod5(argument1, argument2, argument3)
//     .someMethod6(argument1, argument2, argument3)
//     .someMethod7(argument1, argument2, argument3)
//     .someMethod8(argument1, argument2, argument3)
//     .someMethod9(argument1, argument2, argument3)
//     .someMethod10(argument1, argument2, argument3)
//     .someMethod11(argument1, argument2, argument3)
//     .someMethod12(argument1, argument2, argument3)
//     .someMethod13(argument1, argument2, argument3)
//     .someMethod14(argument1, argument2, argument3)
//     .someMethod15(argument1, argument2, argument3)
//     .someMethod16(argument1, argument2, argument3)
//     .someMethod17(argument1, argument2, argument3)
//     .someMethod18(argument1, argument2, argument3)
//     .someMethod19(argument1, argument2, argument3)
//     .someMethod20(argument1, argument2, argument3);
// ''');

  // _formatUnit('''
  // class C {}
  // ''');

  _runTest('tall/variable/local.stmt', 226);
}

void _formatStmt(String source, {bool tall = true, int pageWidth = 40}) {
  _runFormatter(source, pageWidth, tall: tall, isCompilationUnit: false);
}

void _formatUnit(String source, {bool tall = true, int pageWidth = 40}) {
  _runFormatter(source, pageWidth, tall: tall, isCompilationUnit: true);
}

void _runFormatter(String source, int pageWidth,
    {required bool tall, required bool isCompilationUnit}) {
  try {
    var formatter = DartFormatter(
        pageWidth: pageWidth,
        experimentFlags: [if (tall) tallStyleExperimentFlag]);

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
Future<void> _runTest(String path, int line, {bool tall = true}) async {
  var testFile = await TestFile.read(path);
  var formatTest = testFile.tests.firstWhere((test) => test.line == line);

  var formatter = DartFormatter(
      pageWidth: testFile.pageWidth,
      indent: formatTest.leadingIndent,
      fixes: formatTest.fixes,
      experimentFlags: tall
          ? const ['inline-class', tallStyleExperimentFlag]
          : const ['inline-class']);

  var actual = formatter.formatSource(formatTest.input);

  // The test files always put a newline at the end of the expectation.
  // Statements from the formatter (correctly) don't have that, so add
  // one to line up with the expected result.
  var actualText = actual.textWithSelectionMarkers;
  if (!testFile.isCompilationUnit) actualText += '\n';

  var expectedText = formatTest.output.textWithSelectionMarkers;

  print('$path ${formatTest.description}');
  _drawRuler('before', formatter.pageWidth);
  print(formatTest.input.textWithSelectionMarkers);
  if (actualText == expectedText) {
    _drawRuler('result', formatter.pageWidth);
    print(actualText);
  } else {
    print('FAIL');
    _drawRuler('expected', formatter.pageWidth);
    print(expectedText);
    _drawRuler('actual', formatter.pageWidth);
    print(actualText);
  }
}
