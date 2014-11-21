// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.debug;

/// Set this to `true` to turn out diagnostic output while formatting.
bool debugFormatter = false;

bool useAnsiColors = false;

/// Constants for ANSI color escape codes.
class Color {
  static final cyan = _color("\u001b[36m");
  static final gray = _color("\u001b[1;30m");
  static final green = _color("\u001b[32m");
  static final red = _color("\u001b[31m");
  static final magenta = _color("\u001b[35m");
  static final none = _color("\u001b[0m");
  static final noColor = _color("\u001b[39m");
  static final bold = _color("\u001b[1m");
}

String _color(String ansiEscape) => useAnsiColors ? ansiEscape : "";
