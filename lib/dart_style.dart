// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'src/source_visitor.dart';

/// Formatter options.
class FormatterOptions {
  /// Create formatter options with defaults derived (where defined) from
  /// the style guide: <http://www.dartlang.org/articles/style-guide/>.
  const FormatterOptions({this.initialIndentationLevel: 0,
                 this.lineSeparator: "\n",
                 this.pageWidth: 80});

  final String lineSeparator;
  final int initialIndentationLevel;
  final int pageWidth;
}

/// Thrown when an error occurs in formatting.
class FormatterException implements Exception {
  /// A message describing the error.
  final String message;

  /// Creates a new FormatterException with an optional error [message].
  const FormatterException(this.message);

  factory FormatterException.forErrors(List<AnalysisError> errors,
      [LineInfo lines]) {
    var buffer = new StringBuffer();

    for (var error in errors) {
      // Show position information if we have it.
      var pos;
      if (lines != null) {
        var start = lines.getLocation(error.offset);
        var end = lines.getLocation(error.offset + error.length);
        pos = "${start.lineNumber}:${start.columnNumber}-";
        if (start.lineNumber == end.lineNumber) {
          pos += "${end.columnNumber}";
        } else {
          pos += "${end.lineNumber}:${end.columnNumber}";
        }
      } else {
        pos = "${error.offset}...${error.offset + error.length}";
      }
      buffer.writeln("$pos: ${error.message}");
    }

    return new FormatterException(buffer.toString());
  }

  String toString() => message;
}

/// Specifies the kind of code snippet to format.
class CodeKind {
  /// A compilation unit snippet.
  static const COMPILATION_UNIT = const CodeKind._(0);

  /// A statement snippet.
  static const STATEMENT = const CodeKind._(1);

  final int _index;

  const CodeKind._(this._index);
}

/// Source selection state information.
class Selection {
  /// The offset of the source selection.
  final int offset;

  /// The length of the selection.
  final int length;

  Selection(this.offset, this.length);

  String toString() => 'Selection (offset: $offset, length: $length)';
}

/// Dart source code formatter.
class CodeFormatter implements AnalysisErrorListener {
  final FormatterOptions options;
  final errors = <AnalysisError>[];
  final whitespace = new RegExp(r'[\s]+');

  LineInfo lineInfo;

  CodeFormatter([this.options = const FormatterOptions()]);

  /// Format the specified portion (from [offset] with [length]) of the given
  /// [source] string, optionally providing an [indentationLevel].
  String format(CodeKind kind, String source, {int offset, int end,
      int indentationLevel: 0}) {
    var startToken = _tokenize(source);
    _checkForErrors();

    var node = _parse(kind, startToken);
    _checkForErrors();

    var visitor = new SourceVisitor(options, lineInfo, source);
    node.accept(visitor);

    return visitor.writer.toString();
  }

  void onError(AnalysisError error) {
    errors.add(error);
  }

  /// Throws a [FormatterException] if any errors have been reported.
  void _checkForErrors() {
    if (errors.length > 0) {
      throw new FormatterException.forErrors(errors, lineInfo);
    }
  }

  Token _tokenize(String source) {
    var reader = new CharSequenceReader(source);
    var scanner = new Scanner(null, reader, this);
    var token = scanner.tokenize();
    lineInfo = new LineInfo(scanner.lineStarts);
    return token;
  }

  AstNode _parse(CodeKind kind, Token start) {
    var parser = new Parser(null, this);

    parser.parseAsync = true;

    switch (kind) {
      case CodeKind.COMPILATION_UNIT:
        return parser.parseCompilationUnit(start);
      case CodeKind.STATEMENT:
        return parser.parseStatement(start);
    }

    throw new FormatterException('Unsupported format kind: $kind');
  }
}
