// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.dart_formatter;

import 'dart:math' as math;

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/dart/scanner/reader.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/string_source.dart';

import 'error_listener.dart';
import 'exceptions.dart';
import 'source_code.dart';
import 'source_visitor.dart';
import 'string_compare.dart' as string_compare;
import 'style_fix.dart';

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

  /// The number of characters of indentation to prefix the output lines with.
  final int indent;

  final Set<StyleFix> fixes = Set();

  /// Creates a new formatter for Dart code.
  ///
  /// If [lineEnding] is given, that will be used for any newlines in the
  /// output. Otherwise, the line separator will be inferred from the line
  /// endings in the source file.
  ///
  /// If [indent] is given, that many levels of indentation will be prefixed
  /// before each resulting line in the output.
  ///
  /// While formatting, also applies any of the given [fixes].
  DartFormatter(
      {this.lineEnding, int pageWidth, int indent, Iterable<StyleFix> fixes})
      : pageWidth = pageWidth ?? 80,
        indent = indent ?? 0 {
    if (fixes != null) this.fixes.addAll(fixes);
  }

  /// Formats the given [source] string containing an entire Dart compilation
  /// unit.
  ///
  /// If [uri] is given, it is a [String] or [Uri] used to identify the file
  /// being formatted in error messages.
  String format(String source, {uri}) {
    if (uri == null) {
      // Do nothing.
    } else if (uri is Uri) {
      uri = uri.toString();
    } else if (uri is String) {
      // Do nothing.
    } else {
      throw ArgumentError("uri must be `null`, a Uri, or a String.");
    }

    return formatSource(SourceCode(source, uri: uri, isCompilationUnit: true))
        .text;
  }

  /// Formats the given [source] string containing a single Dart statement.
  String formatStatement(String source) {
    return formatSource(SourceCode(source, isCompilationUnit: false)).text;
  }

  /// Formats the given [source].
  ///
  /// Returns a new [SourceCode] containing the formatted code and the resulting
  /// selection, if any.
  SourceCode formatSource(SourceCode source) {
    var errorListener = ErrorListener();

    // Enable all features that are enabled by default in the current analyzer
    // version.
    // TODO(paulberry): consider plumbing in experiment enable flags from the
    // command line.
    var featureSet = FeatureSet.fromEnableFlags([
      "extension-methods",
      "non-nullable",
    ]);

    // Tokenize the source.
    var reader = CharSequenceReader(source.text);
    var stringSource = StringSource(source.text, source.uri);
    var scanner = Scanner(stringSource, reader, errorListener);
    scanner.configureFeatures(featureSet);
    var startToken = scanner.tokenize();
    var lineInfo = LineInfo(scanner.lineStarts);

    // Infer the line ending if not given one. Do it here since now we know
    // where the lines start.
    if (lineEnding == null) {
      // If the first newline is "\r\n", use that. Otherwise, use "\n".
      if (scanner.lineStarts.length > 1 &&
          scanner.lineStarts[1] >= 2 &&
          source.text[scanner.lineStarts[1] - 2] == '\r') {
        lineEnding = "\r\n";
      } else {
        lineEnding = "\n";
      }
    }

    errorListener.throwIfErrors();

    // Parse it.
    var parser = Parser(stringSource, errorListener, featureSet: featureSet);
    parser.enableOptionalNewAndConst = true;
    parser.enableSetLiterals = true;

    AstNode node;
    if (source.isCompilationUnit) {
      node = parser.parseCompilationUnit(startToken);
    } else {
      node = parser.parseStatement(startToken);

      // Make sure we consumed all of the source.
      var token = node.endToken.next;
      if (token.type != TokenType.EOF) {
        var error = AnalysisError(
            stringSource,
            token.offset,
            math.max(token.length, 1),
            ParserErrorCode.UNEXPECTED_TOKEN,
            [token.lexeme]);

        throw FormatterException([error]);
      }
    }

    errorListener.throwIfErrors();

    // Format it.
    var visitor = SourceVisitor(this, lineInfo, source);
    var output = visitor.run(node);

    // Sanity check that only whitespace was changed if that's all we expect.
    if (fixes.isEmpty &&
        !string_compare.equalIgnoringWhitespace(source.text, output.text)) {
      throw UnexpectedOutputException(source.text, output.text);
    }

    return output;
  }
}
