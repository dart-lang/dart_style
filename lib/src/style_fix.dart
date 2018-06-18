// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Enum-like class for the different syntactic fixes that can be applied while
/// formatting.
class StyleFix {
  static const namedDefaultSeparator = const StyleFix._(
      "named-default-separator",
      'Use "=" as the separator before named parameter default values.');

  static const optionalConst = const StyleFix._(
      "optional-const", 'Remove "const" keyword inside constant context.');

  static const optionalNew =
      const StyleFix._("optional-new", 'Remove "new" keyword.');

  static const all = const [namedDefaultSeparator, optionalConst, optionalNew];

  final String name;
  final String description;

  const StyleFix._(this.name, this.description);
}
