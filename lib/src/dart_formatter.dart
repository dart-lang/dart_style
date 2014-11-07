// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.code_formatter;

import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'error_listener.dart';
import 'source_visitor.dart';

/// Dart source code formatter.
class DartFormatter {
  /// The string that newlines should use.
  ///
  /// If not explicitly provided, this is inferred from the source text. If the
  /// first newline is `\r\n` (Windows), it will use that. Otherwise, it uses
  /// Unix-style line endings (`\n`).
  String lineEnding;

  /// The number of characters allowed in a single line.
  final int pageWidth;

  /// The number of levels of indentation to prefix the output lines with.
  final int indent;

  /// Creates a new formatter for Dart code.
  ///
  /// If [lineEnding] is given, that will be used for any newlines in the
  /// output. Otherwise, the line separator will be inferred from the line
  /// endings in the source file.
  ///
  /// If [indent] is given, that many levels of indentation will be prefixed
  /// before each resulting line in the output.
  DartFormatter({this.lineEnding, this.pageWidth: 80, this.indent: 0});

  /// Format the given [source] string containing an entire Dart compilation
  /// unit.
  ///
  /// If [indent] is given, that many levels of indentation will be prefixed
  /// before each resulting line in the output.
  String format(String source) {
    return _format(source,
        (parser, start) => parser.parseCompilationUnit(start));
  }

  /// Format the given [source] string containing a single Dart statement.
  String formatStatement(String source) {
    return _format(source, (parser, start) => parser.parseStatement(start));
  }

  String _format(String source, parseFn(Parser parser, Token start)) {
    var errorListener = new ErrorListener();
    var startToken = _tokenize(source, errorListener);
    errorListener.throwIfErrors();

    var parser = new Parser(null, errorListener);
    parser.parseAsync = true;

    var node = parseFn(parser, startToken);
    errorListener.throwIfErrors();

    var buffer = new StringBuffer();
    var visitor = new SourceVisitor(this, errorListener.lineInfo, source,
        buffer);

    visitor.run(node);

    return buffer.toString();
  }

  Token _tokenize(String source, ErrorListener errorListener) {
    var reader = new CharSequenceReader(source);
    var scanner = new Scanner(null, reader, errorListener);
    var token = scanner.tokenize();
    errorListener.lineInfo = new LineInfo(scanner.lineStarts);

    // Infer the line ending if not given one. Do it here since now we know
    // where the lines start.
    if (lineEnding == null) {
      // If the first newline is "\r\n", use that. Otherwise, use "\n".
      if (scanner.lineStarts.length > 1 &&
          scanner.lineStarts[1] >= 2 &&
          source[scanner.lineStarts[1] - 2] == '\r') {
        lineEnding = "\r\n";
      } else {
        lineEnding = "\n";
      }
    }

    return token;
  }
}
