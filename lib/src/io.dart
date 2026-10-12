// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cli/formatter_options.dart';
import 'config_cache.dart';
import 'dart_formatter.dart';
import 'exceptions.dart';
import 'source_code.dart';

/// Reads and formats input from stdin until closed.
Future<void> formatStdin(
  FormatterOptions options,
  List<int>? selection,
  String? path,
) async {
  var selectionStart = 0;
  var selectionLength = 0;

  if (selection != null) {
    selectionStart = selection[0];
    selectionLength = selection[1];
  }

  var formatter = await _createFormatter(
    options,
    ConfigCache(),
    path != null ? File(path) : null,
  );

  var name = path ?? 'stdin';

  var completer = Completer<void>();
  var input = StringBuffer();

  void onDone() {
    try {
      options.beforeFile(null, name);
      var source = SourceCode(
        input.toString(),
        uri: path,
        selectionStart: selectionStart,
        selectionLength: selectionLength,
      );
      var output = formatter.formatSource(source);
      options.afterFile(
        null,
        name,
        output,
        changed: source.text != output.text,
      );
    } on FormatterException catch (error) {
      _reportParseError(error);
    } catch (error, stack) {
      _reportInternalError('stdin', error, stack);
    }

    completer.complete();
  }

  stdin.transform(const Utf8Decoder()).listen(input.write, onDone: onDone);

  return completer.future;
}

/// Formats all of the files and directories given by [paths].
Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  // If the user didn't specify a language version, then look for surrounding
  // package configs so we know what language versions to use for the files.
  var cache = ConfigCache();

  for (var path in paths) {
    if (Directory(path) case var directory when directory.existsSync()) {
      await _processDirectory(cache, options, directory);
    } else if (File(path) case var file when file.existsSync()) {
      await _processFile(cache, options, file);
    } else {
      stderr.writeln('No file or directory found at "$path".');
    }
  }
}

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
Future<void> _processDirectory(
  ConfigCache cache,
  FormatterOptions options,
  Directory directory,
) async {
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

    await _processFile(cache, options, entry, p.normalize(entry.path));
  }
}

/// Runs the formatter on [file].
Future<void> _processFile(
  ConfigCache cache,
  FormatterOptions options,
  File file, [
  String? displayPath,
]) async {
  displayPath ??= file.path;
  var formatter = await _createFormatter(options, cache, file, displayPath);

  try {
    var source = SourceCode(file.readAsStringSync(), uri: file.path);
    options.beforeFile(file, displayPath);
    var output = formatter.formatSource(source);
    options.afterFile(
      file,
      displayPath,
      output,
      changed: source.text != output.text,
    );
  } on FormatterException catch (error) {
    _reportParseError(error);
  } catch (error, stack) {
    _reportInternalError(displayPath, error, stack);
  }
}

/// Creates a [DartFormatter] configured using the given explicit options and
/// any surrounding `analysis_options.yaml` file (if [file] is given).
Future<DartFormatter> _createFormatter(
  FormatterOptions options,
  ConfigCache cache,
  File? file, [
  String? displayPath,
]) async {
  // Explicitly passed arguments take precedence.
  var languageVersion = options.languageVersion;
  var pageWidth = options.pageWidth;
  var trailingCommas = options.trailingCommas;
  var experimentFlags = options.experimentFlags;

  // If we have a file path, look for options from a surrounding
  // analysis_options.yaml file.
  if (file != null) {
    languageVersion ??= await cache.findLanguageVersion(
      file,
      displayPath ?? file.path,
    );
    pageWidth ??= await cache.findPageWidth(file);
    trailingCommas ??= await cache.findTrailingCommas(file);

    if (experimentFlags.isEmpty) {
      experimentFlags = await cache.findExperimentFlags(file);
    }
  }

  // Fill in the defaults if we weren't otherwise given values.
  languageVersion ??= DartFormatter.latestLanguageVersion;
  pageWidth ??= DartFormatter.defaultPageWidth;

  return DartFormatter(
    languageVersion: languageVersion,
    indent: options.indent,
    pageWidth: pageWidth,
    trailingCommas: trailingCommas,
    experimentFlags: experimentFlags,
  );
}

void _reportParseError(FormatterException exception) {
  var color =
      Platform.operatingSystem != 'windows' &&
      stdioType(stderr) == StdioType.terminal;

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
