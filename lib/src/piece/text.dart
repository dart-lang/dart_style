// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../back_end/code_writer.dart';
import 'piece.dart';

/// A simple atomic piece of code.
///
/// This may represent a series of tokens where no split can occur between them.
/// It may also contain one or more comments.
sealed class TextPiece extends Piece {
  /// RegExp that matches any valid Dart line terminator.
  static final _lineTerminatorPattern = RegExp(r'\r\n?|\n');

  /// The lines of text in this piece.
  ///
  /// Most [TextPieces] will contain only a single line, but a piece for a
  /// multi-line string or comment will have multiple lines. These are stored
  /// as separate lines instead of a single multi-line Dart String so that
  /// line endings are normalized and so that column calculation during line
  /// splitting calculates each line in the piece separately.
  final List<String> _lines = [''];

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int? _selectionEnd;

  /// Append [text] to the end of this piece.
  ///
  /// If [text] may contain any newline characters, then [multiline] must be
  /// `true`.
  ///
  /// If [selectionStart] and/or [selectionEnd] are given, then notes that the
  /// corresponding selection markers appear that many code units from where
  /// [text] will be appended.
  void append(String text,
      {bool multiline = false, int? selectionStart, int? selectionEnd}) {
    if (selectionStart != null) {
      _selectionStart = _adjustSelection(selectionStart);
    }

    if (selectionEnd != null) {
      _selectionEnd = _adjustSelection(selectionEnd);
    }

    if (multiline) {
      var lines = text.split(_lineTerminatorPattern);
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) _lines.add('');
        _lines.last += lines[i];
      }
    } else {
      _lines.last += text;
    }
  }

  /// Adjust [offset] by the current length of this [TextPiece].
  int _adjustSelection(int offset) {
    for (var line in _lines) {
      offset += line.length;
    }

    return offset;
  }

  void _formatSelection(CodeWriter writer) {
    if (_selectionStart case var start?) {
      writer.startSelection(start);
    }

    if (_selectionEnd case var end?) {
      writer.endSelection(end);
    }
  }

  void _formatLines(CodeWriter writer) {
    for (var i = 0; i < _lines.length; i++) {
      if (i > 0) writer.newline(flushLeft: i > 0);
      writer.write(_lines[i]);
    }
  }

  @override
  bool calculateContainsHardNewline() => _lines.length > 1;

  @override
  int calculateTotalCharacters() {
    var total = 0;

    for (var line in _lines) {
      total += line.length;
    }

    return total;
  }

  @override
  String toString() => '`${_lines.join('¬')}`';
}

/// [TextPiece] for non-comment source code that may have comments attached to
/// it.
final class CodePiece extends TextPiece {
  /// Pieces for any comments that appear immediately before this code.
  final List<Piece> _leadingComments;

  /// Pieces for any comments that hang off the same line as this code.
  final List<Piece> _hangingComments = [];

  CodePiece([this._leadingComments = const []]);

  void addHangingComment(Piece comment) {
    _hangingComments.add(comment);
  }

  @override
  void format(CodeWriter writer, State state) {
    _formatSelection(writer);

    if (_leadingComments.isNotEmpty) {
      // Always put leading comments on a new line.
      writer.newline();

      for (var comment in _leadingComments) {
        writer.format(comment);
      }
    }

    _formatLines(writer);

    for (var comment in _hangingComments) {
      writer.space();
      writer.format(comment);
    }
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    _leadingComments.forEach(callback);
    _hangingComments.forEach(callback);
  }
}

/// A [TextPiece] for a source code comment and the whitespace after it, if any.
final class CommentPiece extends TextPiece {
  /// Whitespace at the end of the comment.
  final Whitespace _trailingWhitespace;

  CommentPiece(this._trailingWhitespace);

  @override
  void format(CodeWriter writer, State state) {
    _formatSelection(writer);
    _formatLines(writer);
    writer.whitespace(_trailingWhitespace);
  }

  @override
  bool calculateContainsHardNewline() =>
      _trailingWhitespace.hasNewline || super.calculateContainsHardNewline();

  @override
  void forEachChild(void Function(Piece piece) callback) {}
}

/// A piece for the special `// dart format off` and `// dart format on`
/// comments that are used to opt a region of code out of being formatted.
final class EnableFormattingCommentPiece extends CommentPiece {
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

  EnableFormattingCommentPiece(this._sourceOffset, super._trailingWhitespace,
      {required bool enable})
      : _enabled = enable;

  @override
  void format(CodeWriter writer, State state) {
    super.format(writer, state);
    writer.setFormattingEnabled(_enabled, _sourceOffset);
  }
}

/// A piece that writes a single space.
final class SpacePiece extends Piece {
  @override
  void forEachChild(void Function(Piece piece) callback) {}

  @override
  void format(CodeWriter writer, State state) {
    writer.space();
  }

  @override
  bool calculateContainsHardNewline() => false;

  @override
  int calculateTotalCharacters() => 1;
}

/// A piece that writes a single newline.
final class NewlinePiece extends Piece {
  @override
  void forEachChild(void Function(Piece piece) callback) {}

  @override
  void format(CodeWriter writer, State state) {
    writer.newline();
  }

  @override
  bool calculateContainsHardNewline() => true;

  @override
  int calculateTotalCharacters() => 0;
}
