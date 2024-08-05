// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'cli/formatter_options.dart';
import 'constants.dart';
import 'dart_formatter.dart';
import 'exceptions.dart';
import 'language_version_cache.dart';
import 'source_code.dart';

/// Reads and formats input from stdin until closed.
Future<void> formatStdin(
    FormatterOptions options, List<int>? selection, String name) async {
  var selectionStart = 0;
  var selectionLength = 0;

  if (selection != null) {
    selectionStart = selection[0];
    selectionLength = selection[1];
  }

  var completer = Completer<void>();
  var input = StringBuffer();
  stdin.transform(const Utf8Decoder()).listen(input.write, onDone: () {
    var formatter = DartFormatter(
        languageVersion: options.languageVersion,
        indent: options.indent,
        pageWidth: options.pageWidth,
        fixes: options.fixes,
        experimentFlags: options.experimentFlags);
    try {
      options.beforeFile(null, name);
      var source = SourceCode(input.toString(),
          uri: name,
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
  LanguageVersionCache? cache;
  if (options.languageVersion == null) {
    // TODO(rnystrom): Remove the experiment check when the experiment ships.
    if (options.experimentFlags.contains(tallStyleExperimentFlag)) {
      cache = LanguageVersionCache();
    }
  }

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
Future<bool> _processDirectory(LanguageVersionCache? cache,
    FormatterOptions options, Directory directory) async {
  options.showDirectory(directory.path);

  var success = true;
  var shownHiddenPaths = <String>{};

  var entries =
      directory.listSync(recursive: true, followLinks: options.followLinks);
  entries.sort((a, b) => a.path.compareTo(b.path));

  for (var entry in entries) {
    var displayPath = options.show.displayPath(directory.path, entry.path);

    if (entry is Link) {
      options.showSkippedLink(displayPath);
      continue;
    }

    if (entry is! File || !entry.path.endsWith('.dart')) continue;

    // If the path is in a subdirectory starting with ".", ignore it.
    var parts = p.split(p.relative(entry.path, from: directory.path));
    int? hiddenIndex;
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].startsWith('.')) {
        hiddenIndex = i;
        break;
      }
    }

    if (hiddenIndex != null) {
      // Since we'll hide everything inside the directory starting with ".",
      // show the directory name once instead of once for each file.
      var hiddenPath = p.joinAll(parts.take(hiddenIndex + 1));
      if (shownHiddenPaths.add(hiddenPath)) {
        options.showHiddenPath(hiddenPath);
      }
      continue;
    }

    if (!await _processFile(cache, options, entry, displayPath: displayPath)) {
      success = false;
    }
  }

  return success;
}

/// Runs the formatter on [file].
///
/// Returns `true` if successful or `false` if an error occurred.
Future<bool> _processFile(
    LanguageVersionCache? cache, FormatterOptions options, File file,
    {String? displayPath}) async {
  displayPath ??= file.path;

  // Determine what language version to use. If we have a language version
  // cache, that implies that we should use the surrounding package config to
  // infer the file's language version. Otherwise, use the user-provided
  // version.
  Version? languageVersion;
  if (cache != null) {
    try {
      // Look for a package config. If we don't find one, default to the latest
      // language version.
      languageVersion = await cache.find(file);
    } catch (error) {
      stderr.writeln('Could not read package configuration for '
          '$displayPath:\n$error');
      stderr.writeln('To avoid searching for a package configuration, '
          'specify a language version using "--language-version".');
      return false;
    }
  } else {
    languageVersion = options.languageVersion;
  }

  var formatter = DartFormatter(
      languageVersion: languageVersion ?? DartFormatter.latestLanguageVersion,
      indent: options.indent,
      pageWidth: options.pageWidth,
      fixes: options.fixes,
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
