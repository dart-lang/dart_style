// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'back_end/worker_pool.dart';
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

  var trailingCommas = options.trailingCommas;
  if (trailingCommas == null && path != null) {
    // We have a stdin-name, so look for a surrounding analyisis_options.yaml.
    trailingCommas = await cache.findTrailingCommas(File(path));
  }

  // Use a default page width if we don't have a specified one and couldn't
  // find a configured one.
  pageWidth ??= DartFormatter.defaultPageWidth;

  var name = path ?? 'stdin';

  var completer = Completer<void>();
  var input = StringBuffer();

  void onDone() {
    var formatter = DartFormatter(
      languageVersion: languageVersion!,
      indent: options.indent,
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
      experimentFlags: options.experimentFlags,
    );
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
  }

  stdin.transform(const Utf8Decoder()).listen(input.write, onDone: onDone);

  return completer.future;
}

/// Formats all of the files and directories given by [paths].
Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  if (!await _processFileStream(options, _expandPaths(paths, options))) {
    exitCode = 65;
  }
}

/// Expands [paths] into a stream of files to format.
Stream<File> _expandPaths(List<String> paths, FormatterOptions options) async* {
  var seen = <String>{};
  for (var path in paths) {
    var directory = Directory(path);
    if (directory.existsSync()) {
      await for (var entry in directory.list(
        recursive: true,
        followLinks: options.followLinks,
      )) {
        if (entry is Link) continue;
        if (entry is! File || !entry.path.endsWith('.dart')) continue;

        // Ignore paths in hidden directories.
        var parts = p.split(p.relative(entry.path, from: directory.path));
        if (parts.any((part) => part.startsWith('.'))) continue;

        if (seen.add(p.canonicalize(entry.path))) {
          yield entry;
        }
      }
      continue;
    }

    var file = File(path);
    if (file.existsSync()) {
      if (seen.add(p.canonicalize(file.path))) {
        yield file;
      }
    } else {
      stderr.writeln('No file or directory found at "$path".');
    }
  }
}

/// Runs the formatter on a stream of files using a worker pool.
Future<bool> _processFileStream(
  FormatterOptions options,
  Stream<File> files,
) async {
  var cache = ConfigCache();
  var success = true;
  var pool = WorkerPool();

  await for (var file in files) {
    var displayPath = p.normalize(file.path);

    // Determine configuration in main isolate (leveraging cache).
    var languageVersion =
        options.languageVersion ??
        await cache.findLanguageVersion(file, displayPath);
    languageVersion ??= DartFormatter.latestLanguageVersion;

    var pageWidth = options.pageWidth ?? await cache.findPageWidth(file);
    var trailingCommas =
        options.trailingCommas ?? await cache.findTrailingCommas(file);
    pageWidth ??= DartFormatter.defaultPageWidth;

    options.beforeFile(file, displayPath);

    await pool.add(
      uri: file.path,
      languageVersion: languageVersion,
      indent: options.indent,
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
      experimentFlags: options.experimentFlags,
      onResult: (response) {
        if (response.error != null) {
          if (response.isFormatterException) {
            stderr.writeln(response.error);
          } else {
            stderr.writeln(
              'Hit a bug in the formatter when formatting $displayPath.\n'
              '${response.error}\n'
              '${response.stackTrace}',
            );
          }
          success = false;
          return;
        }

        var output = SourceCode(
          response.text!,
          uri: file.path,
          selectionStart: response.selectionStart,
          selectionLength: response.selectionLength,
        );

        options.afterFile(file, displayPath, output, changed: response.changed);
      },
    );
  }
  var telemetry = await pool.close();
  options.summary.addTelemetry(telemetry);

  await pool.close();
  return success;
}
