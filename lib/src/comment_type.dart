// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
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
  ///     code /* comment
  ///       more */
  inlineBlock;

  /// Whether a comment of this type may contain newlines inside its lexeme.
  bool get mayBeMultiline => this != line;
}
