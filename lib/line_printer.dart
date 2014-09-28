// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.line_breaker;

import 'line.dart';

/// Converts a [Line] to a single flattened [String].
class LinePrinter {
  final int pageWidth;

  /// Creates a new breaker that tries to fit lines within [pageWidth].
  LinePrinter({this.pageWidth});

  /// Convert this [line] to a [String] representation.
  String printLine(Line line) {
    var buffer = new StringBuffer();
    buffer.write(" " * (line.indent * SPACES_PER_INDENT));
    buffer.writeAll(line.tokens);
    return buffer.toString();
  }
}
