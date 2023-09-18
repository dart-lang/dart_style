// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'selection.dart';

enum CommentType {
  /// A `///` or `/**` doc comment.
  doc,

  /// A non-doc line comment.
  line,

  /// A `/* ... */` comment that should be on its own line.
  ///
  /// These occur when the block comment doesn't appear with any code on the
  /// same line preceding the `/*` or after the `*/`.
  block,

  /// A `/* ... */` comment that can share a line with other code.
  ///
  /// These occur when there is code on the same line either immediately
  /// preceding the `/*`, after the `*/`, or both. An inline block comment
  /// may be multiple lines, as in:
  ///
  /// ```
  /// code /* comment
  ///   more */
  /// ```
  inlineBlock,
}

/// A comment in the source, with a bit of information about the surrounding
/// whitespace.
class SourceComment extends Selection {
  /// The text of the comment, including `//`, `/*`, and `*/`.
  @override
  final String text;

  final CommentType type;

  /// The number of newlines between the comment or token preceding this comment
  /// and the beginning of this one.
  ///
  /// Will be zero if the comment is a trailing one.
  int linesBefore;

  /// Whether this comment starts at column one in the source.
  ///
  /// Comments that start at the start of the line will not be indented in the
  /// output. This way, commented out chunks of code do not get erroneously
  /// re-indented.
  final bool flushLeft;

  SourceComment(this.text, this.type, this.linesBefore,
      {required this.flushLeft});
}
