// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/formatter_options.dart' as a;
import 'package:path/path.dart' as p;

import '../dart_formatter.dart';
import '../exceptions.dart';
import '../source_code.dart';
import 'analyzer.dart';
import 'formatter_options.dart';

/// Reads and formats input from stdin until closed.
Future<void> formatStdin(
  FormatterOptions options,
  List<int>? selection,
  String? path,
) async {
  var completer = Completer<void>();
  var input = StringBuffer();

  void onDone() async {
    var selectionStart = selection?[0] ?? 0;
    var selectionLength = selection?[1] ?? 0;
    var name = path ?? 'stdin';
    try {
      options.beforeFile(null, name);

      var stdin = input.toString();
      SourceCode output;
      if (path != null) {
        output = await _formatStdinWithPath(
          options,
          stdin,
          path,
          selectionStart,
          selectionLength,
        );
      } else {
        output = _formatStdinWithoutPath(
          options,
          stdin,
          selectionStart,
          selectionLength,
        );
      }

      options.afterFile(null, name, output, changed: stdin != output.text);
    } on FormatterException catch (error) {
      _reportParseError(error);
    } catch (error, stackTrace) {
      _reportInternalError(name, error, stackTrace);
    }

    completer.complete();
  }

  stdin.transform(const Utf8Decoder()).listen(input.write, onDone: onDone);

  return completer.future;
}

/// Formats Dart code from [stdin] when given a synthetic [path] for it.
///
/// In that case, we use the analyzer to create a context so that the language
/// version and formatting options for the code can be inferred from the
/// package config and `analysis_options.yaml` files surrounding [path].
Future<SourceCode> _formatStdinWithPath(
  FormatterOptions options,
  String stdin,
  String path,
  int selectionStart,
  int selectionLength,
) async {
  var absolutePath = p.normalize(p.absolute(path));
  var analyzer = Analyzer.forStdinPath(
    stdin: stdin,
    path: absolutePath,
    languageVersion: options.languageVersion,
    experimentFlags: options.experimentFlags,
  );

  try {
    var (output, changed: _) = _formatFromAnalyzer(
      analyzer,
      options,
      absolutePath,
      selectionStart: selectionStart,
      selectionLength: selectionLength,
    );

    return output;
  } finally {
    await analyzer.dispose();
  }
}

/// Formats Dart code from [stdin] with no given path.
///
/// Since there is no path to use for an analysis context, it formats using any
/// explicitly given options or otherwise uses the defaults.
SourceCode _formatStdinWithoutPath(
  FormatterOptions options,
  String stdin,
  int selectionStart,
  int selectionLength,
) {
  var formatter = DartFormatter(
    languageVersion:
        options.languageVersion ?? DartFormatter.latestLanguageVersion,
    indent: options.indent,
    pageWidth: options.pageWidth,
    trailingCommas: options.trailingCommas,
    experimentFlags: options.experimentFlags,
  );

  return formatter.formatSource(
    SourceCode(
      stdin,
      selectionStart: selectionStart,
      selectionLength: selectionLength,
    ),
  );
}

/// Format all of the files and the contents of directories in [paths].
Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  var absolutePaths = <String>[];
  var displayPaths = <String>[];

  for (var path in paths) {
    var directory = Directory(path);
    if (directory.existsSync()) {
      var entries = directory.listSync(
        recursive: true,
        followLinks: options.followLinks,
      );
      entries.sort((a, b) => a.path.compareTo(b.path));

      for (var entry in entries) {
        if (entry is Link) continue;
        if (entry is! File || !entry.path.endsWith('.dart')) continue;

        // If the path is in a subdirectory starting with ".", ignore it.
        var parts = p.split(p.relative(entry.path, from: directory.path));
        if (parts.any((part) => part.startsWith('.'))) continue;

        absolutePaths.add(p.normalize(p.absolute(entry.path)));
        displayPaths.add(p.normalize(entry.path));
      }
    } else {
      if (File(path).existsSync()) {
        absolutePaths.add(p.normalize(p.absolute(path)));
        displayPaths.add(p.normalize(path));
      } else {
        stderr.writeln('No file or directory found at "$path".');
      }
    }
  }

  var analyzer = Analyzer.forFiles(
    absolutePaths,
    languageVersion: options.languageVersion,
    experimentFlags: options.experimentFlags,
  );

  try {
    for (var i = 0; i < absolutePaths.length; i++) {
      var absolutePath = absolutePaths[i];
      var displayPath = displayPaths[i];

      try {
        options.beforeFile(absolutePath, displayPath);

        var (output, :changed) = _formatFromAnalyzer(
          analyzer,
          options,
          absolutePath,
        );
        options.afterFile(absolutePath, displayPath, output, changed: changed);
      } on FormatterException catch (error) {
        _reportParseError(error);
      } catch (error, stackTrace) {
        _reportInternalError(displayPath, error, stackTrace);
      }
    }
  } finally {
    await analyzer.dispose();
  }
}

/// Uses [analyzer] to read [path] and any surrounding options and then formats
/// the result using any provided [options].
///
/// Returns the resulting formatted output and `true` if the output is
/// different from the original input.
(SourceCode, {bool changed}) _formatFromAnalyzer(
  Analyzer analyzer,
  FormatterOptions options,
  String path, {
  int? selectionStart,
  int? selectionLength,
}) {
  var (parsedResult, analysisOptions) = analyzer.read(options, path);

  var formatter = DartFormatter(
    languageVersion:
        options.languageVersion ?? parsedResult.unit.languageVersion.package,
    indent: options.indent,
    pageWidth:
        options.pageWidth ??
        analysisOptions.formatterOptions.pageWidth ??
        DartFormatter.defaultPageWidth,
    trailingCommas:
        options.trailingCommas ??
        switch (analysisOptions.formatterOptions.trailingCommas) {
          // Note: Not using dot shorthands here because this switch converts
          // between two confusing classes with the same names and members.
          null => TrailingCommas.automate,
          a.TrailingCommas.automate => TrailingCommas.automate,
          a.TrailingCommas.preserve => TrailingCommas.preserve,
        },
    // TODO(rnystrom): Should get any experiment flags enabled in
    // [analysisOptions] and pass them in here if [options.experimentFlags] is
    // empty. But it doesn't seem like the [AnalysisOptions] class exposes
    // the list of experiment flags directly, and the formatter doesn't
    // actually use them anyway, so don't bother trying to send them along.
    // (Only the parser uses experiment flags, and the
    // AnalysisContextCollection will send them to the parser.)
    experimentFlags: options.experimentFlags,
  );

  var output = formatUnitResult(
    formatter,
    parsedResult,
    selectionStart: selectionStart,
    selectionLength: selectionLength,
  );

  return (output, changed: parsedResult.content != output.text);
}

void _reportParseError(FormatterException exception) {
  var color =
      Platform.operatingSystem != 'windows' && stdioType(stderr) == .terminal;

  stderr.writeln(exception.message(color: color));

  // An internal error is more severe than the user giving the formatter bad
  // Dart syntax, so only set the exit code here if we haven't had an internal
  // error.
  if (exitCode != 70) exitCode = 65; // sysexits.h: EX_DATAERR
}

void _reportInternalError(
  String displayPath,
  Object error,
  StackTrace stackTrace,
) {
  stderr.writeln('Hit a bug in the formatter when formatting $displayPath.');
  stderr.writeln(error);
  if (error is! UnexpectedOutputException) stderr.writeln(stackTrace);
  stderr.writeln('Please report at github.com/dart-lang/dart_style/issues.');

  exitCode = 70; // sysexits.h: EX_SOFTWARE
}
