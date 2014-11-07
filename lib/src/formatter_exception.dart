// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.formatter_exception;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/source.dart';

/// Thrown when an error occurs in formatting.
class FormatterException implements Exception {
  /// A message describing the error.
  final String message;

  /// Creates a new FormatterException with an optional error [message].
  const FormatterException(this.message);

  factory FormatterException.forErrors(List<AnalysisError> errors,
      [LineInfo lines]) {
    var buffer = new StringBuffer();

    for (var error in errors) {
      // Show position information if we have it.
      var pos;
      if (lines != null) {
        var start = lines.getLocation(error.offset);
        var end = lines.getLocation(error.offset + error.length);
        pos = "${start.lineNumber}:${start.columnNumber}-";
        if (start.lineNumber == end.lineNumber) {
          pos += "${end.columnNumber}";
        } else {
          pos += "${end.lineNumber}:${end.columnNumber}";
        }
      } else {
        pos = "${error.offset}...${error.offset + error.length}";
      }
      buffer.writeln("$pos: ${error.message}");
    }

    return new FormatterException(buffer.toString());
  }

  String toString() => message;
}
