// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(rnystrom): Now that the formatter may add and remove trailing commas
// and reposition comments relative to `,`, `[`, `]`, `{`, and `}`, this
// function is getting less and less precise. (For example, a bug in the
// formatter that dropped all `[` tokens on the floor would still pass.)
// Consider a more sophisticated approach for determining that the formatter
// preserved all of the original code.

/// Returns `true` if [c] represents a whitespace code unit allowed in Dart
/// source code.
///
/// This mostly follows the same rules as `String.trim()` because that's what
/// dart_style uses to trim trailing whitespace.
///
/// This function treats `,` as a whitespace character since the formatter will
/// add and remove trailing commas. It treats, `[`, `]`, `{`, and `}` as
/// whitespace characters because the formatter may move a comment if it
/// appears near the closing delimiter of an optional parameter section.
///
/// It treats `;` as whitespace because a trailing `;` inside an enum
/// declaration that has no members will be removed.
bool _isWhitespace(int c) {
  // Not using a set or something more elegant because this code is on the hot
  // path and this large expression is significantly faster than a set lookup.
  return c == 0x002c || // Treat commas as "whitespace".
      c == 0x005b || // Treat `[` as "whitespace".
      c == 0x005d || // Treat `]` as "whitespace".
      c == 0x007b || // Treat `{` as "whitespace".
      c == 0x007d || // Treat `}` as "whitespace".
      c == 0x003b || // Treat `;` as "whitespace".
      c >= 0x0009 && c <= 0x000d || // Control characters.
      c == 0x0020 || // SPACE.
      c == 0x0085 || // Control characters.
      c == 0x00a0 || // NO-BREAK SPACE.
      c == 0x1680 || // OGHAM SPACE MARK.
      c >= 0x2000 && c <= 0x200a || // EN QUAD..HAIR SPACE.
      c == 0x2028 || // LINE SEPARATOR.
      c == 0x2029 || // PARAGRAPH SEPARATOR.
      c == 0x202f || // NARROW NO-BREAK SPACE.
      c == 0x205f || // MEDIUM MATHEMATICAL SPACE.
      c == 0x3000 || // IDEOGRAPHIC SPACE.
      c == 0xfeff; // ZERO WIDTH NO_BREAK SPACE.
}

/// Returns the index of the next non-whitespace character.
///
/// Returns `true` if current contains a non-whitespace character.
/// Returns `false` if no characters are left.
int _moveNextNonWhitespace(String str, int len, int i) {
  while (i < len && _isWhitespace(str.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// Returns `true` if the strings are equal ignoring whitespace characters.
///
/// This function treats commas as "whitespace", so that it correctly ignores
/// differences from the formatter inserting or removing trailing commas.
///
/// Note that the function ignores *all* commas in the compared strings, not
/// just trailing ones. It's possible that a bug in the formatter which changes
/// commas in non-trailing positions would not be caught by this function.
///
/// We risk that in order to make this function faster, since it is only a
/// sanity check to catch bugs in the formatter itself and the character by
/// character checking of this function is a performance bottleneck.
bool equalIgnoringWhitespace(String str1, String str2) {
  // Benchmarks showed about a 20% regression in formatter performance when
  // when we use the simpler to implement solution of stripping all
  // whitespace characters and checking string equality. This solution is
  // faster due to lower memory usage and poor performance concatting strings
  // together one rune at a time.

  var len1 = str1.length;
  var len2 = str2.length;
  var i1 = 0;
  var i2 = 0;

  while (true) {
    i1 = _moveNextNonWhitespace(str1, len1, i1);
    i2 = _moveNextNonWhitespace(str2, len2, i2);
    if (i1 >= len1 || i2 >= len2) {
      return (i1 >= len1) == (i2 >= len2);
    }

    if (str1[i1] != str2[i2]) return false;
    i1++;
    i2++;
  }
}
