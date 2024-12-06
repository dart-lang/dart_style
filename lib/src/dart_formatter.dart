// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:math' as math;

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/scanner/scanner.dart';
// ignore: implementation_imports
import 'package:analyzer/src/string_source.dart';
import 'package:pub_semver/pub_semver.dart';

import 'exceptions.dart';
import 'front_end/ast_node_visitor.dart';
import 'short/source_visitor.dart';
import 'source_code.dart';
import 'string_compare.dart' as string_compare;

/// Regular expression that matches a format width comment like:
///
///     // dart format width=123
final RegExp _widthCommentPattern = RegExp(r'^// dart format width=(\d+)$');

/// A Dart source code formatter.
///
/// This is a lightweight class that mostly bundles formatting options so that
/// you don't have to pass a long argument list to [format()] and
/// [formatStatement()]. You can efficiently create a new instance of this for
/// every format invocation.
final class DartFormatter {
  /// The latest Dart language version that can be parsed and formatted by this
  /// version of the formatter.
  static final latestLanguageVersion = Version(3, 7, 0);

  /// The latest Dart language version that will be formatted using the older
  /// "short" style.
  ///
  /// Any Dart code at a language version later than this will be formatted
  /// using the new "tall" style.
  static final latestShortStyleLanguageVersion = Version(3, 6, 0);

  /// The page width that the formatter tries to fit code inside if no other
  /// width is specified.
  static const defaultPageWidth = 80;

  /// The Dart language version that formatted code should be parsed as.
  ///
  /// Note that a `// @dart=` comment inside the code overrides this.
  final Version languageVersion;

  /// The string that newlines should use.
  ///
  /// If not explicitly provided, this is inferred from the source text. If the
  /// first newline is `\r\n` (Windows), it will use that. Otherwise, it uses
  /// Unix-style line endings (`\n`).
  String? lineEnding;

  /// The number of characters allowed in a single line.
  final int pageWidth;

  /// The number of characters of indentation to prefix the output lines with.
  final int indent;

  /// Flags to enable experimental language features.
  ///
  /// See dart.dev/go/experiments for details.
  final List<String> experimentFlags;

  /// Creates a new formatter for Dart code at [languageVersion].
  ///
  /// If [lineEnding] is given, that will be used for any newlines in the
  /// output. Otherwise, the line separator will be inferred from the line
  /// endings in the source file.
  ///
  /// If [indent] is given, that many levels of indentation will be prefixed
  /// before each resulting line in the output.
  DartFormatter(
      {required this.languageVersion,
      this.lineEnding,
      int? pageWidth,
      int? indent,
      List<String>? experimentFlags})
      : pageWidth = pageWidth ?? defaultPageWidth,
        indent = indent ?? 0,
        experimentFlags = [...?experimentFlags];

  /// Formats the given [source] string containing an entire Dart compilation
  /// unit.
  ///
  /// If [uri] is given, it is a [String] or [Uri] used to identify the file
  /// being formatted in error messages.
  String format(String source, {Object? uri}) {
    var uriString = switch (uri) {
      null => null,
      Uri() => uri.toString(),
      String() => uri,
      _ => throw ArgumentError('uri must be `null`, a Uri, or a String.'),
    };

    return formatSource(
            SourceCode(source, uri: uriString, isCompilationUnit: true))
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
    var inputOffset = 0;
    var text = source.text;
    var unitSourceCode = source;

    // If we're parsing a single statement, wrap the source in a fake function.
    if (!source.isCompilationUnit) {
      var prefix = 'void foo() { ';
      inputOffset = prefix.length;
      text = '$prefix$text\n }';
      unitSourceCode = SourceCode(
        text,
        uri: source.uri,
        isCompilationUnit: false,
        selectionStart: source.selectionStart != null
            ? source.selectionStart! + inputOffset
            : null,
        selectionLength: source.selectionLength,
      );
    }

    var featureSet = FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: languageVersion, flags: experimentFlags);

    // Parse it.
    var parseResult = parseString(
        content: text,
        featureSet: featureSet,
        path: source.uri,
        throwIfDiagnostics: false);

    // Infer the line ending if not given one. Do it here since now we know
    // where the lines start.
    if (lineEnding == null) {
      // If the first newline is "\r\n", use that. Otherwise, use "\n".
      var lineStarts = parseResult.lineInfo.lineStarts;
      if (lineStarts.length > 1 &&
          lineStarts[1] >= 2 &&
          text[lineStarts[1] - 2] == '\r') {
        lineEnding = '\r\n';
      } else {
        lineEnding = '\n';
      }
    }

    // Throw if there are syntactic errors.
    var syntacticErrors = parseResult.errors.where((error) {
      return error.errorCode.type == ErrorType.SYNTACTIC_ERROR;
    }).toList();
    if (syntacticErrors.isNotEmpty) {
      throw FormatterException(syntacticErrors);
    }

    AstNode node;
    if (source.isCompilationUnit) {
      node = parseResult.unit;
    } else {
      var function = parseResult.unit.declarations[0] as FunctionDeclaration;
      var body = function.functionExpression.body as BlockFunctionBody;
      node = body.block.statements[0];

      // Make sure we consumed all of the source.
      var token = node.endToken.next!;
      if (token.type != TokenType.CLOSE_CURLY_BRACKET) {
        var stringSource = StringSource(text, source.uri);
        var error = AnalysisError.tmp(
            source: stringSource,
            offset: token.offset - inputOffset,
            length: math.max(token.length, 1),
            errorCode: ParserErrorCode.UNEXPECTED_TOKEN,
            arguments: [token.lexeme]);
        throw FormatterException([error]);
      }
    }

    // Format it.
    var lineInfo = parseResult.lineInfo;

    // If the code has an `@dart=` comment, use that to determine the style.
    var sourceLanguageVersion = languageVersion;
    if (parseResult.unit.languageVersionToken case var token?) {
      sourceLanguageVersion = Version(token.major, token.minor, 0);
    }

    // Use language version to determine what formatting style to apply.
    SourceCode output;
    if (sourceLanguageVersion > latestShortStyleLanguageVersion) {
      // Look for a page width comment before the code.
      int? pageWidthFromComment;
      for (Token? comment = node.beginToken.precedingComments;
          comment != null;
          comment = comment.next) {
        if (_widthCommentPattern.firstMatch(comment.lexeme) case var match?) {
          // If integer parsing fails for some reason, the returned `null`
          // means we correctly ignore the comment.
          pageWidthFromComment = int.tryParse(match[1]!);
          break;
        }
      }

      var visitor = AstNodeVisitor(this, lineInfo, unitSourceCode);
      output = visitor.run(unitSourceCode, node, pageWidthFromComment);
    } else {
      // Use the old style.
      var visitor = SourceVisitor(this, lineInfo, unitSourceCode);
      output = visitor.run(node);
    }

    // Sanity check that only whitespace was changed if that's all we expect.
    if (!string_compare.equalIgnoringWhitespace(source.text, output.text)) {
      throw UnexpectedOutputException(source.text, output.text);
    }

    return output;
  }
}
