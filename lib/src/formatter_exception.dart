// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.formatter_exception;

import 'package:analyzer/analyzer.dart';
import 'package:source_span/source_span.dart';

/// Thrown when one or more errors occurs while parsing the code to be
/// formatted.
class FormatterException implements Exception {
  /// The [AnalysisError]s that occurred.
  final List<AnalysisError> errors;

  /// Creates a new FormatterException with an optional error [message].
  const FormatterException(this.errors);

  /// Creates a human-friendly representation of the analysis errors.
  String message() {
    var buffer = new StringBuffer();
    buffer.writeln("Could not format because the source could not be parsed:");

    for (var error in errors) {
      var file = new SourceFile(error.source.contents.data,
          url: error.source.fullName);

      var span = file.span(error.offset, error.offset + error.length);
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.write(span.message(error.message, color: true));
    }

    return buffer.toString();
  }

  String toString() => message();
}
