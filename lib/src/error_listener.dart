// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.error_listener;

import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/error/syntactic_errors.dart';

import 'exceptions.dart';

/// A simple [AnalysisErrorListener] that just collects the reported errors.
class ErrorListener implements AnalysisErrorListener {
  final _errors = <AnalysisError>[];

  String get autoInsertMissingSemiColonCode {
    bool isMissingSemiColonError(AnalysisError error) =>
        error.errorCode == ParserErrorCode.EXPECTED_TOKEN &&
        error.message.contains("';'");

    if (_errors.isEmpty || !_errors.every(isMissingSemiColonError)) {
      return null;
    }

    final needSemiColonPositions = _errors.map((e) => e.offset + e.length);
    final code = _errors[0].source.contents.data;
    var curr = 0;
    return needSemiColonPositions
            .map((i) => code.substring(curr, curr = i) + ';')
            .join() +
        code.substring(curr);
  }

  @override
  void onError(AnalysisError error) {
    // Fasta produces some semantic errors, which we want to ignore so that
    // users can format code containing static errors.
    if (error.errorCode.type != ErrorType.SYNTACTIC_ERROR) return;

    _errors.add(error);
  }

  /// Throws a [FormatterException] if any errors have been reported.
  void throwIfErrors() {
    if (_errors.isEmpty) return;

    throw FormatterException(_errors);
  }
}
