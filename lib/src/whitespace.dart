// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.whitespace;

/// The kind of pending whitespace that has been "written", but not actually
/// physically output yet.
///
/// We defer actually writing whitespace until a non-whitespace token is
/// encountered to avoid trailing whitespace.
class Whitespace {
  /// A single non-breaking space.
  static const SPACE = const Whitespace._("SPACE");

  /// A single newline.
  static const NEWLINE = const Whitespace._("NEWLINE");

  /// A single newline that takes into account the current expression nesting
  /// for the next line.
  static const NESTED_NEWLINE = const Whitespace._("NESTED_NEWLINE");

  /// A single newline with all indentation eliminated at the beginning of the
  /// next line.
  ///
  /// Used for subsequent lines in a multiline string.
  static const NEWLINE_FLUSH_LEFT = const Whitespace._("NEWLINE_FLUSH_LEFT");

  /// Two newlines, a single blank line of separation.
  static const TWO_NEWLINES = const Whitespace._("TWO_NEWLINES");

  /// A space or newline should be output based on whether the current token is
  /// on the same line as the previous one or not.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const SPACE_OR_NEWLINE = const Whitespace._("SPACE_OR_NEWLINE");

  /// One or two newlines should be output based on how many newlines are
  /// present between the next token and the previous one.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const ONE_OR_TWO_NEWLINES = const Whitespace._("ONE_OR_TWO_NEWLINES");

  final String name;

  const Whitespace._(this.name);

  String toString() => name;
}
