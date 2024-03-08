// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:math' as math;

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/scanner/scanner.dart';
// ignore: implementation_imports
import 'package:analyzer/src/string_source.dart';
import 'package:pub_semver/pub_semver.dart';

import 'constants.dart';
import 'exceptions.dart';
import 'front_end/ast_node_visitor.dart';
import 'short/source_visitor.dart';
import 'short/style_fix.dart';
import 'source_code.dart';
import 'string_compare.dart' as string_compare;

/// Dart source code formatter.
class DartFormatter {
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

  final Set<StyleFix> fixes;

  /// Flags to enable experimental language features.
  ///
  /// See dart.dev/go/experiments for details.
  final List<String> experimentFlags;

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
      {this.lineEnding,
      int? pageWidth,
      int? indent,
      Iterable<StyleFix>? fixes,
      List<String>? experimentFlags})
      : pageWidth = pageWidth ?? 80,
        indent = indent ?? 0,
        fixes = {...?fixes},
        experimentFlags = [...?experimentFlags];

  /// Formats the given [source] string containing an entire Dart compilation
  /// unit.
  ///
  /// If [uri] is given, it is a [String] or [Uri] used to identify the file
  /// being formatted in error messages.
  String format(String source, {Object? uri}) {
    if (uri == null) {
      // Do nothing.
    } else if (uri is Uri) {
      uri = uri.toString();
    } else if (uri is String) {
      // Do nothing.
    } else {
      throw ArgumentError('uri must be `null`, a Uri, or a String.');
    }

    return formatSource(
            SourceCode(source, uri: uri as String?, isCompilationUnit: true))
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
      text = '$prefix$text }';
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

    // Parse it.
    var parseResult = _parse(text, source.uri, patterns: true);

    // If we couldn't parse it with patterns enabled, it may be because of
    // one of the breaking syntax changes to switch cases. Try parsing it
    // again without patterns.
    if (parseResult.errors.isNotEmpty) {
      var withoutPatternsResult = _parse(text, source.uri, patterns: false);

      // If we succeeded this time, use this parse instead.
      if (withoutPatternsResult.errors.isEmpty) {
        parseResult = withoutPatternsResult;
      }
    }

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

    SourceCode output;
    if (experimentFlags.contains(tallStyleExperimentFlag)) {
      var visitor = AstNodeVisitor(this, lineInfo, unitSourceCode);
      output = visitor.run(node);
    } else {
      var visitor = SourceVisitor(this, lineInfo, unitSourceCode);
      output = visitor.run(node);
    }

    // Sanity check that only whitespace was changed if that's all we expect.
    if (fixes.isEmpty &&
        !string_compare.equalIgnoringWhitespace(source.text, output.text)) {
      throw UnexpectedOutputException(source.text, output.text);
    }

    return output;
  }

  /// Parse [source] from [uri].
  ///
  /// If [patterns] is `true`, the parse at the latest language version
  /// which supports patterns and treats switch cases as patterns. If `false`,
  /// then parses using an older language version where switch cases are
  /// constant expressions.
  ///
  // TODO(rnystrom): This is a pretty big hack. Up until now, every language
  // version was a strict syntactic superset of all previous versions. That let
  // the formatter parse every file at the latest language version without
  // having to detect each file's actual version, which requires digging around
  // in the file system for package configs and looking for "@dart" comments in
  // files. It also means the library API that parses arbitrary strings doesn't
  // have to worry about what version the code should be interpreted as.
  //
  // But with patterns, a small number of switch cases are no longer
  // syntactically valid. Breakage from this is very rare. Instead of adding
  // the machinery to detect language versions (which is likely to be slow and
  // brittle), we just try parsing everything with patterns enabled. When a
  // parse error occurs, we try parsing it again with pattern disabled. If that
  // happens to parse without error, then we use that result instead.
  ParseStringResult _parse(String source, String? uri,
      {required bool patterns}) {
    var version = patterns ? Version(3, 3, 0) : Version(2, 19, 0);

    // Don't pass the formatter's own experiment flag to the parser.
    var experiments = experimentFlags.toList();
    experiments.remove(tallStyleExperimentFlag);

    var featureSet = FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: version, flags: experiments);

    return parseString(
      content: source,
      featureSet: featureSet,
      path: uri,
      throwIfDiagnostics: false,
    );
  }
}
