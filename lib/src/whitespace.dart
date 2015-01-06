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
  static const space = const Whitespace._("space");

  /// A single newline.
  static const newline = const Whitespace._("newline");

  /// A single newline that takes into account the current expression nesting
  /// for the next line.
  static const nestedNewline = const Whitespace._("nestedNewline");

  /// A single newline with all indentation eliminated at the beginning of the
  /// next line.
  ///
  /// Used for subsequent lines in a multiline string.
  static const newlineFlushLeft = const Whitespace._("newlineFlushLeft");

  /// Two newlines, a single blank line of separation.
  static const twoNewlines = const Whitespace._("twoNewlines");

  /// A space or newline should be output based on whether the current token is
  /// on the same line as the previous one or not.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const spaceOrNewline = const Whitespace._("spaceOrNewline");

  /// One or two newlines should be output based on how many newlines are
  /// present between the next token and the previous one.
  ///
  /// In general, we like to avoid using this because it makes the formatter
  /// less prescriptive over the user's whitespace.
  static const oneOrTwoNewlines = const Whitespace._("oneOrTwoNewlines");

  final String name;

  const Whitespace._(this.name);

  String toString() => name;
}
