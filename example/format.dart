// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/debug.dart' as debug;
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

  // _formatStmt('''
  // 1 + 2;
  // ''');

  _formatUnit('''
  import 'dart:io';
  // import 'dart:math';

  import 'foo.dart';
  ''');
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
