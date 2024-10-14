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
    FormatterOptions options, List<int>? selection, String? path) async {
  var selectionStart = 0;
  var selectionLength = 0;

  if (selection != null) {
    selectionStart = selection[0];
    selectionLength = selection[1];
  }

  var cache = ConfigCache();

  var languageVersion = options.languageVersion;
  if (languageVersion == null && path != null) {
    // We have a stdin-name, so look for a surrounding package config.
    languageVersion = await cache.findLanguageVersion(File(path), path);
  }

  // If they didn't specify a version or a path, or couldn't find a package
  // surrounding the path, then default to the latest version.
  languageVersion ??= DartFormatter.latestLanguageVersion;

  // Determine the page width.
  var pageWidth = options.pageWidth;
  if (pageWidth == null && path != null) {
    // We have a stdin-name, so look for a surrounding analyisis_options.yaml.
    pageWidth = await cache.findPageWidth(File(path));
  }

  // Use a default page width if we don't have a specified one and couldn't
  // find a configured one.
  pageWidth ??= DartFormatter.defaultPageWidth;

  var name = path ?? 'stdin';

  var completer = Completer<void>();
  var input = StringBuffer();
  stdin.transform(const Utf8Decoder()).listen(input.write, onDone: () {
    var formatter = DartFormatter(
        languageVersion: languageVersion!,
        indent: options.indent,
        pageWidth: pageWidth,
        experimentFlags: options.experimentFlags);
    try {
      options.beforeFile(null, name);
      var source = SourceCode(input.toString(),
          uri: path,
          selectionStart: selectionStart,
          selectionLength: selectionLength);
      var output = formatter.formatSource(source);
      options.afterFile(null, name, output,
          changed: source.text != output.text);
    } on FormatterException catch (err) {
      stderr.writeln(err.message());
      exitCode = 65; // sysexits.h: EX_DATAERR
    } catch (err, stack) {
      stderr.writeln('''Hit a bug in the formatter when formatting stdin.
Please report at: github.com/dart-lang/dart_style/issues
$err
$stack''');
      exitCode = 70; // sysexits.h: EX_SOFTWARE
    }

    completer.complete();
  });

  return completer.future;
}

/// Formats all of the files and directories given by [paths].
Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  // If the user didn't specify a language version, then look for surrounding
  // package configs so we know what language versions to use for the files.
  var cache = ConfigCache();

  for (var path in paths) {
    var directory = Directory(path);
    if (directory.existsSync()) {
      if (!await _processDirectory(cache, options, directory)) {
        exitCode = 65;
      }
      continue;
    }

    var file = File(path);
    if (file.existsSync()) {
      if (!await _processFile(cache, options, file)) {
        exitCode = 65;
      }
    } else {
      stderr.writeln('No file or directory found at "$path".');
    }
  }
}

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
///
/// Returns `true` if successful or `false` if an error occurred in any of the
/// files.
Future<bool> _processDirectory(
    ConfigCache cache, FormatterOptions options, Directory directory) async {
  var success = true;

  var entries =
      directory.listSync(recursive: true, followLinks: options.followLinks);
  entries.sort((a, b) => a.path.compareTo(b.path));

  for (var entry in entries) {
    if (entry is Link) continue;

    if (entry is! File || !entry.path.endsWith('.dart')) continue;

    // If the path is in a subdirectory starting with ".", ignore it.
    var parts = p.split(p.relative(entry.path, from: directory.path));
    if (parts.any((part) => part.startsWith('.'))) continue;

    if (!await _processFile(cache, options, entry,
        displayPath: p.normalize(entry.path))) {
      success = false;
    }
  }

  return success;
}

/// Runs the formatter on [file].
///
/// Returns `true` if successful or `false` if an error occurred.
Future<bool> _processFile(
    ConfigCache cache, FormatterOptions options, File file,
    {String? displayPath}) async {
  displayPath ??= file.path;

  // Determine what language version to use.
  var languageVersion = options.languageVersion ??
      await cache.findLanguageVersion(file, displayPath);

  // If they didn't specify a version and we couldn't find a surrounding
  // package, then default to the latest version.
  languageVersion ??= DartFormatter.latestLanguageVersion;

  // Determine the page width.
  var pageWidth = options.pageWidth ?? await cache.findPageWidth(file);

  // Use a default page width if we don't have a specified one and couldn't
  // find a configured one.
  pageWidth ??= DartFormatter.defaultPageWidth;

  var formatter = DartFormatter(
      languageVersion: languageVersion,
      indent: options.indent,
      pageWidth: pageWidth,
      experimentFlags: options.experimentFlags);

  try {
    var source = SourceCode(file.readAsStringSync(), uri: file.path);
    options.beforeFile(file, displayPath);
    var output = formatter.formatSource(source);
    options.afterFile(file, displayPath, output,
        changed: source.text != output.text);
    return true;
  } on FormatterException catch (err) {
    var color = Platform.operatingSystem != 'windows' &&
        stdioType(stderr) == StdioType.terminal;

    stderr.writeln(err.message(color: color));
  } on UnexpectedOutputException catch (err) {
    stderr.writeln('''Hit a bug in the formatter when formatting $displayPath.
$err
Please report at github.com/dart-lang/dart_style/issues.''');
  } catch (err, stack) {
    stderr.writeln('''Hit a bug in the formatter when formatting $displayPath.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''');
  }

  return false;
}
