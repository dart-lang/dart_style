// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Base class for an object that represents fully formatted code.
///
/// We use this instead of immediately generating a string for the resulting
/// formatted code because of separate formatting. Often, a subtree of the
/// [Piece] tree can be solved and formatted separately. The resulting
/// [Solution] may be used by multiple different surrounding solutions while
/// the [Solver] works its magic looking for the best solution. When a
/// separately formatted child solution is merged into its parent, we want that
/// to be fast. Appending strings to a [StringBuffer] is fairly fast, but not
/// as fast simply appending a single [GroupCode] to the parent solution's
/// [GroupCode].
sealed class Code {}

/// A [Code] object which can be written to and contain other child [Code]
/// objects.
final class GroupCode extends Code {
  /// The child [Code] objects contained in this group.
  final List<Code> _children = [];

  /// Appends [text] to this code.
  void write(String text) {
    _children.add(_TextCode(text));
  }

  /// Writes a newline and the subsequent indentation to this code.
  ///
  /// If [blank] is `true`, then a blank line is written. Otherwise, only a
  /// single newline is written. The [indent] parameter is the number of spaces
  /// of leading indentation on the next line after the newline.
  void newline({required bool blank, required int indent}) {
    _children.add(_NewlineCode(blank: blank, indent: indent));
  }

  /// Adds an entire existing code [group] as a child of this one.
  void group(GroupCode group) {
    _children.add(group);
  }

  /// Mark the selection start as occurring [offset] characters after the code
  /// that has already been written.
  void startSelection(int offset) {
    _children.add(_MarkerCode(_Marker.start, offset));
  }

  /// Mark the selection end as occurring [offset] characters after the code
  /// that has already been written.
  void endSelection(int offset) {
    _children.add(_MarkerCode(_Marker.end, offset));
  }

  /// Traverse the [Code] tree and build the final formatted string.
  ///
  /// Returns the formatted string and the selection markers if there are any.
  ({String code, int? selectionStart, int? selectionEnd}) build() {
    var buffer = StringBuffer();
    int? selectionStart;
    int? selectionEnd;

    _build(buffer, (marker, offset) {
      if (marker == _Marker.start) {
        selectionStart = offset;
      } else {
        selectionEnd = offset;
      }
    });

    return (
      code: buffer.toString(),
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    );
  }

  void _build(StringBuffer buffer,
      void Function(_Marker marker, int offset) markSelection) {
    for (var i = 0; i < _children.length; i++) {
      var child = _children[i];
      switch (child) {
        case _NewlineCode():
          // Don't write any leading newlines at the top of the buffer.
          if (i > 0) {
            buffer.writeln();
            if (child._blank) buffer.writeln();
          }

          buffer.write(_indents[child._indent] ?? (' ' * child._indent));

        case _TextCode():
          buffer.write(child._text);

        case GroupCode():
          child._build(buffer, markSelection);

        case _MarkerCode():
          markSelection(child._marker, buffer.length + child._offset);
      }
    }
  }
}

/// A [Code] object for a newline followed by any leading indentation.
final class _NewlineCode extends Code {
  final bool _blank;
  final int _indent;

  _NewlineCode({required bool blank, required int indent})
      : _indent = indent,
        _blank = blank;
}

/// A [Code] object for literal source text.
final class _TextCode extends Code {
  final String _text;

  _TextCode(this._text);
}

/// Marks the location of the beginning or end of a selection as occurring
/// [_offset] characters past the point where this marker object appears in the
/// list of [Code] objects.
final class _MarkerCode extends Code {
  /// What kind of selection endpoint is being marked.
  final _Marker _marker;

  /// The number of characters past this object where the marker should appear
  /// in the resulting code.
  final int _offset;

  _MarkerCode(this._marker, this._offset);
}

/// Which selection marker is pointed to by a [_MarkerCode].
enum _Marker { start, end }

/// Pre-calculated whitespace strings for various common levels of indentation.
///
/// Generating these ahead of time is faster than concatenating multiple spaces
/// at runtime.
const _indents = {
  2: '  ',
  4: '    ',
  6: '      ',
  8: '        ',
  10: '          ',
  12: '            ',
  14: '              ',
  16: '                ',
  18: '                  ',
  20: '                    ',
  22: '                      ',
  24: '                        ',
  26: '                          ',
  28: '                            ',
  30: '                              ',
  32: '                                ',
  34: '                                  ',
  36: '                                    ',
  38: '                                      ',
  40: '                                        ',
  42: '                                          ',
  44: '                                            ',
  46: '                                              ',
  48: '                                                ',
  50: '                                                  ',
  52: '                                                    ',
  54: '                                                      ',
  56: '                                                        ',
  58: '                                                          ',
  60: '                                                            ',
};
