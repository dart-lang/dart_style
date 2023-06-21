/// Returns `true` if [c] represents a whitespace code unit allowed in Dart
/// source code.
///
/// This mostly follows the same rules as `String.trim()` because that's what
/// dart_style uses to trim trailing whitespace as well as considering `,` to
/// be a whitespace character since the formatter will add and remove trailing
/// commas.
bool _isWhitespace(int c) {
  // Not using a set or something more elegant because this code is on the hot
  // path and this large expression is significantly faster than a set lookup.
  return c == 0x002c || // Treat commas as "whitespace".
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

/// Returns the next non-whitespace character.
///
/// Searches [str] for non-whitespace characters, starting at [i]
/// and ending at [len].
///
/// Skips whitespace characters *and* single backslashes before whitespace
/// characters. The latter is allowed to account for the first line
/// of multiline strings (but does risk allowing the removal of a backslash
/// from a raw string.)
///
/// Returns the index of the next non-whitespace character
/// starting from [i], or [len] if there are no non-whitespace
/// characters between [i] and [len].
int _moveNextNonWhitespace(String str, int len, int i) {
  const backslash = 0x5C;
  while (i < len) {
    var c = str.codeUnitAt(i);
    if (_isWhitespace(c)) {
      i += 1;
    } else if (c == backslash &&
        i + 1 < len &&
        _isWhitespace(str.codeUnitAt(i + 1))) {
      i += 2;
    } else {
      break;
    }
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
    if (str1.codeUnitAt(i1) != str2.codeUnitAt(i2)) {
      return false;
    }
    i1++;
    i2++;
  }
}
