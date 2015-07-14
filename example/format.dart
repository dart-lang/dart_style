// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';

import 'package:dart_style/src/debug.dart' as debug;

void main(List<String> args) {
  // Enable debugging so you can see some of the formatter's internal state.
  // Normal users do not do this.
  debug.traceChunkBuilder = true;
  //debug.traceLineWriter = true;
  //debug.traceSplitter = true;
  debug.useAnsiColors = true;

  formatStmt("""
  init({@Option(
      help: 'The git Uri containing the jefe.yaml.',
      abbr: 'g') String gitUri, @Option(
      help: 'The directory to install into',
      abbr: 'd') String installDirectory: '.', @Flag(
      help: 'Skips the checkout of the develop branch',
      abbr: 's') bool skipCheckout: false}) async {}
""", 80);
}

void formatStmt(String source, [int pageWidth = 40]) {
  runFormatter(source, pageWidth, isCompilationUnit: false);
}

void formatUnit(String source, [int pageWidth = 40]) {
  runFormatter(source, pageWidth, isCompilationUnit: true);
}

void runFormatter(String source, int pageWidth, {bool isCompilationUnit}) {
  try {
    var formatter = new DartFormatter(pageWidth: pageWidth);

    var result;
    if (isCompilationUnit) {
      result = formatter.format(source);
    } else {
      result = formatter.formatStatement(source);
    }

    if (debug.useAnsiColors) {
      result = result.replaceAll(" ", debug.gray(debug.unicodeMidDot));
    }

    drawRuler("before", pageWidth);
    print(source);
    drawRuler("after", pageWidth);
    print(result);
  } on FormatterException catch (error) {
    print(error.message());
  }
}

void drawRuler(String label, int width) {
  var padding = " " * (width - label.length - 1);
  print("$label:$padding|");
}
