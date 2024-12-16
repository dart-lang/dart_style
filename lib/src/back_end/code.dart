// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../source_code.dart';

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
sealed class Code {
  /// Traverse the [Code] tree and generate a string showing the [Code] tree's
  /// structure for debugging purposes.
  String toCodeTree() {
    var buffer = StringBuffer();
    var prefix = '';

    void write(String text) {
      if (buffer.isNotEmpty) buffer.write(prefix);
      buffer.writeln(text);
    }

    void trace(Code code) {
      switch (code) {
        case _NewlineCode():
          write('Newline(blank: ${code._blank}, indent: ${code._indent})');

        case _TextCode():
          write('`${code._text}`');

        case GroupCode():
          write('Group(indent: ${code._indent}):');
          prefix += '| ';
          for (var child in code._children) {
            trace(child);
          }
          prefix = prefix.substring(2);

        case _MarkerCode():
          write('Marker(${code._marker}, offset: ${code._offset})');

        case _EnableFormattingCode():
          write('EnableFormattingCode(enabled: ${code._enabled}, '
              'offset: ${code._sourceOffset})');
      }
    }

    trace(this);

    return buffer.toString();
  }

  /// Write the [Code] to a string of output code, ignoring selection and
  /// format on/off markers.
  String toDebugString() {
    var builder = _DebugStringBuilder();
    builder.traverse(this);
    return builder.finish();
  }
}

/// A [Code] object which can be written to and contain other child [Code]
/// objects.
final class GroupCode extends Code {
  /// How many spaces the first text inside this group should be indented.
  final int _indent;

  /// The child [Code] objects contained in this group.
  final List<Code> _children = [];

  GroupCode(this._indent);

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
    // Don't insert a redundant newline at the top of a group.
    if (_children.isNotEmpty) {
      _children.add(_NewlineCode(blank: blank, indent: indent));
    }
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

  /// Disables or re-enables formatting in a region of code.
  void setFormattingEnabled(bool enabled, int sourceOffset) {
    _children.add(_EnableFormattingCode(enabled, sourceOffset));
  }

  /// Traverse the [Code] tree and build the final formatted string.
  ///
  /// Whenever a newline is written, writes [lineEnding]. If omitted, defaults
  /// to '\n'.
  ///
  /// Returns the formatted string and the selection markers if there are any.
  SourceCode build(SourceCode source, [String? lineEnding]) {
    lineEnding ??= '\n';

    var builder = _StringBuilder(source, lineEnding);
    builder.traverse(this);
    return builder.finish();
  }
}

/// A [Code] object for a newline followed by any leading indentation.
final class _NewlineCode extends Code {
  /// True if a blank line (two newlines) should be written.
  final bool _blank;

  /// The number of spaces of indentation after this newline.
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

  /// The number of characters into the next [Code] object where the marker
  /// should appear in the resulting output.
  final int _offset;

  _MarkerCode(this._marker, this._offset);
}

final class _EnableFormattingCode extends Code {
  /// Whether this comment disables formatting (`format off`) or re-enables it
  /// (`format on`).
  final bool _enabled;

  /// The number of code points from the beginning of the unformatted source
  /// where the unformatted code should begin or end.
  ///
  /// If this piece is for `// dart format off`, then the offset is just past
  /// the `off`. If this piece is for `// dart format on`, it points to just
  /// before `//`.
  final int _sourceOffset;

  _EnableFormattingCode(this._enabled, this._sourceOffset);
}

/// Which selection marker is pointed to by a [_MarkerCode].
enum _Marker { start, end }

/// Traverses a [Code] tree and produces the final string of output code and
/// the selection markers, if any.
final class _StringBuilder {
  /// Pre-calculated whitespace strings for various common levels of
  /// indentation.
  ///
  /// Generating these ahead of time is faster than concatenating multiple
  /// spaces at runtime.
  static const _indents = {
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

  final SourceCode _source;
  final String _lineEnding;
  final StringBuffer _buffer = StringBuffer();

  /// The offset from the beginning of the source to where the selection start
  /// marker is, if there is one.
  int? _selectionStart;

  /// The offset from the beginning of the source to where the selection end
  /// marker is, if there is one.
  int? _selectionEnd;

  /// How many spaces of indentation should be written before the next text.
  int _indent = 0;

  /// If formatting has been disabled, then this is the offset from the
  /// beginning of the source, to where the disabled formatting begins.
  ///
  /// Otherwise, -1 to indicate that formatting is enabled.
  int _disableFormattingStart = -1;

  _StringBuilder(this._source, this._lineEnding);

  void traverse(Code code) {
    switch (code) {
      case _NewlineCode():
        // If formatting has been disabled, then don't write the formatted
        // output. The unformatted output will be written when formatting is
        // re-enabled.
        if (_disableFormattingStart == -1) {
          _buffer.write(_lineEnding);
          if (code._blank) _buffer.write(_lineEnding);
          _indent = code._indent;
        }

      case _TextCode():
        // If formatting has been disabled, then don't write the formatted
        // output. The unformatted output will be written when formatting is
        // re-enabled.
        if (_disableFormattingStart == -1) {
          // Write any pending indentation.
          _buffer.write(_indents[_indent] ?? (' ' * _indent));
          _indent = 0;

          _buffer.write(code._text);
        }

      case GroupCode():
        _indent = code._indent;
        for (var i = 0; i < code._children.length; i++) {
          var child = code._children[i];
          traverse(child);
        }

      case _MarkerCode():
        if (_disableFormattingStart == -1) {
          // Calculate the absolute offset from the beginning of the formatted
          // output where the selection marker will appear based on how much
          // formatted output we've written, pending indentation, and then the
          // relative offset of the marker into the subsequent [Code] we will
          // write.
          var absolutePosition = _buffer.length + _indent + code._offset;
          switch (code._marker) {
            case _Marker.start:
              _selectionStart = absolutePosition;
            case _Marker.end:
              _selectionEnd = absolutePosition;
          }
        } else {
          // The marker appears inside a region where formatting is disabled.
          // In that case, calculating where the marker will end up in the
          // final formatted output is more complicated because we haven't
          // actually written any of the code between the `// dart format off`
          // comment and this marker to [_buffer] yet. However, we do know the
          // *absolute* position of the selection markers in the original
          // source.
          //
          // Let's say the source file looks like:
          //
          //               1         2         3
          //     0123456789012345678901234567890123456789
          //     bef  +  ore off code | inside on more
          //
          // Here, `bef  +  ore` is some amount of code appearing before
          // formatting is disabled, `off` is the `// dart format off` comment,
          // `code` is some code inside the unformatted region, `|` is the
          // selection marker, `inside` is more code in the unformatted region,
          // `on` turns formatting back on, and `more` is formatted code at the
          // end.
          //
          // We know the beginning of the unformatted region is at offset 15
          // (just after the comment) in the original source. We know the
          // selection marker is at offset 21 in the original source. From that,
          // we know the selection marker should end up 6 code points after the
          // beginning of the unformatted region in the resulting output.
          switch (code._marker) {
            case _Marker.start:
              // Calculate how far into the unformatted code where the marker
              // should appear.
              var markerOffsetInUnformatted =
                  _source.selectionStart! - _disableFormattingStart;
              _selectionStart = _buffer.length + markerOffsetInUnformatted;

            case _Marker.end:
              var end = _source.selectionStart! + _source.selectionLength!;

              // Calculate how far into the unformatted code where the marker
              // should appear.
              var markerOffsetInUnformatted = end - _disableFormattingStart;
              _selectionEnd = _buffer.length + markerOffsetInUnformatted;
          }
        }

      case _EnableFormattingCode(_enabled: false):
        // Region markers don't nest. If we've already turned off formatting,
        // then ignore any subsequent `// dart format off` comments until it's
        // been turned back on.
        if (_disableFormattingStart == -1) {
          _disableFormattingStart = code._sourceOffset;
        }

      case _EnableFormattingCode(_enabled: true):
        // If we didn't disable formatting, then enabling it does nothing.
        if (_disableFormattingStart != -1) {
          // Write all of the unformatted text from the `// dart format off`
          // comment to the end of the `// dart format on` comment.
          _buffer.write(_source.text
              .substring(_disableFormattingStart, code._sourceOffset));
          _disableFormattingStart = -1;
        }
    }
  }

  SourceCode finish() {
    if (_disableFormattingStart != -1) {
      // Formatting was disabled and never re-enabled, so write the rest of the
      // source file as unformatted text.
      _buffer.write(_source.text.substring(_disableFormattingStart));
    } else if (_source.isCompilationUnit) {
      // Be a good citizen, end with a newline.
      _buffer.write(_lineEnding);
    }

    var selectionStart = _selectionStart;
    int? selectionLength;
    if (_source.selectionStart != null) {
      // If we haven't hit the beginning and/or end of the selection yet, they
      // must be at the very end of the code.
      selectionStart ??= _buffer.length;
      var selectionEnd = _selectionEnd ?? _buffer.length;
      selectionLength = selectionEnd - selectionStart;
    }

    return SourceCode(_buffer.toString(),
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: selectionStart,
        selectionLength: selectionLength);
  }
}

/// Traverses a [Code] tree and produces a string of output code, ignoring
/// selection and format on/off markers.
///
/// This is a simpler version of [_StringBuilder] that doesn't require having
/// access to the original [SourceCode] and line ending.
final class _DebugStringBuilder {
  final StringBuffer _buffer = StringBuffer();

  /// How many spaces of indentation should be written before the next text.
  int _indent = 0;

  void traverse(Code code) {
    switch (code) {
      case _NewlineCode():
        _buffer.writeln();
        if (code._blank) _buffer.writeln();
        _indent = code._indent;

      case _TextCode():
        // Write any pending indentation.
        _buffer.write(' ' * _indent);
        _indent = 0;
        _buffer.write(code._text);

      case GroupCode():
        _indent = code._indent;
        for (var i = 0; i < code._children.length; i++) {
          traverse(code._children[i]);
        }

      case _MarkerCode():
      case _EnableFormattingCode():
        // The debug output doesn't support disabled formatting or selections.
        break;
    }
  }

  String finish() => _buffer.toString();
}
