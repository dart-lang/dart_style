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
  /// The latest Dart language version that can be parsed and formatted by this
  /// version of the formatter.
  static final latestLanguageVersion = Version(3, 6, 0);

  /// The highest Dart language version without support for patterns.
  static final _lastNonPatternsVersion = Version(2, 19, 0);

  /// The Dart language version that formatted code should be parsed as.
  ///
  /// Note that a `// @dart=` comment inside the code overrides this.
  final Version languageVersion;

  /// Whether the user passed in a non-`null` language version.
  // TODO(rnystrom): Remove this when the language version is required.
  final bool _omittedLanguageVersion;

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

  /// Creates a new formatter for Dart code at [languageVersion].
  ///
  /// If [languageVersion] is omitted, then it defaults to
  /// [latestLanguageVersion]. In a future major release of dart_style, the
  /// language version will affect the applied formatting style. At that point,
  /// this parameter will become required so that the applied style doesn't
  /// change unexpectedly. It is optional now so that users can migrate to
  /// versions of dart_style that accept this parameter and be ready for the
  /// major version when it's released.
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
      {Version? languageVersion,
      this.lineEnding,
      int? pageWidth,
      int? indent,
      Iterable<StyleFix>? fixes,
      List<String>? experimentFlags})
      : languageVersion = languageVersion ?? latestLanguageVersion,
        _omittedLanguageVersion = languageVersion == null,
        pageWidth = pageWidth ?? 80,
        indent = indent ?? 0,
        fixes = {...?fixes},
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
    var parseResult = _parse(text, source.uri, languageVersion);

    // If we couldn't parse it, and the language version supports patterns, it
    // may be because of the breaking syntax changes to switch cases. Try
    // parsing it again without pattern support.
    // TODO(rnystrom): This is a pretty big hack. Before Dart 3.0, every
    // language version was a strict syntactic superset of all previous
    // versions. When patterns were added, a small number of switch cases
    // became syntax errors.
    //
    // For most of its history, the formatter simply parsed every file at the
    // latest language version without having to detect each file's actual
    // version. We are moving towards requiring the language version when
    // formatting, but for now, try to degrade gracefully if the user omits the
    // version.
    //
    // Remove this when the languageVersion constructor parameter is required.
    if (_omittedLanguageVersion && parseResult.errors.isNotEmpty) {
      var withoutPatternsResult =
          _parse(text, source.uri, _lastNonPatternsVersion);

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
      output = visitor.run(unitSourceCode, node);
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

  /// Parse [source] from [uri] at language [version].
  ParseStringResult _parse(String source, String? uri, Version version) {
    // Don't pass the formatter's own experiment flag to the parser.
    var experiments = experimentFlags.toList();
    experiments.remove(tallStyleExperimentFlag);

    var featureSet = FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: version, flags: experiments);

    return parseString(
        content: source,
        featureSet: featureSet,
        path: uri,
        throwIfDiagnostics: false);
  }
}
