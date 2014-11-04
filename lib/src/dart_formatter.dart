// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.code_formatter;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

import 'source_visitor.dart';

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

/// Dart source code formatter.
class DartFormatter implements AnalysisErrorListener {
  /// The newline separator string.
  final String lineSeparator;

  /// The number of characters allowed in a single line.
  final int pageWidth;

  /// The number of levels of indentation to prefix the output lines with.
  final int indent;

  final errors = <AnalysisError>[];
  final whitespace = new RegExp(r'[\s]+');

  LineInfo lineInfo;

  DartFormatter({this.lineSeparator: "\n", this.pageWidth: 80, this.indent: 0});

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
  ///
  /// If [indent] is given, that many levels of indentation will be prefixed
  /// before each resulting line in the output.
  String formatStatement(String source, {int indent: 0}) {
    return _format(source, (parser, start) => parser.parseStatement(start));
  }

  String _format(String source, parseFn(Parser parser, Token start)) {
    var startToken = _tokenize(source);
    _checkForErrors();

    var parser = new Parser(null, this);
    parser.parseAsync = true;

    var node = parseFn(parser, startToken);
    _checkForErrors();

    var buffer = new StringBuffer();
    var visitor = new SourceVisitor(this, lineInfo, source, buffer);
    node.accept(visitor);

    // Finish off the last line.
    visitor.writer.end();

    return buffer.toString();
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
}
