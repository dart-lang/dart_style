// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

import 'cli/formatter_options.dart';
import 'dart_formatter.dart';
import 'exceptions.dart';
import 'profile.dart';
import 'source_code.dart';

class FormatService {
  final FormatterOptions _options;

  FormatService(this._options);

  /// Formats all of the files and directories given by [paths].
  Future<void> format(List<String> paths) async {
    Profile.begin('FormatService.format()');

    Profile.begin('list paths');
    var files = <File>[];
    for (var path in paths) {
      var directory = Directory(path);
      if (await directory.exists()) {
        files.addAll(await _listDirectory(directory));
        continue;
      }

      var file = File(path);
      if (await file.exists()) {
        files.add(file);
      } else {
        stderr.writeln('No file or directory found at "$path".');
      }
    }
    Profile.end('list paths');

    // TODO: Tune?
    var pool = Pool(Platform.numberOfProcessors);
    for (var file in files) {
      unawaited(pool.withResource(() async {
        await _format(file);
      }));
    }

    await pool.close();

    Profile.end('FormatService.format()');
    Profile.report();
  }

  Future<List<File>> _listDirectory(Directory directory) async {
    var files = <File>[];
    _options.showDirectory(directory.path);

    var shownHiddenPaths = <String>{};

    var entries =
        directory.listSync(recursive: true, followLinks: _options.followLinks);
    entries.sort((a, b) => a.path.compareTo(b.path));

    for (var entry in entries) {
      var displayPath = _options.show.displayPath(directory.path, entry.path);

      if (entry is Link) {
        _options.showSkippedLink(displayPath);
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
          _options.showHiddenPath(hiddenPath);
        }
        continue;
      }

      files.add(entry);
    }

    return files;
  }

  Future<void> _format(File file) async {
    // TODO: Preserve old logic.
    var displayPath = file.path;

    var formatter = DartFormatter(
        indent: _options.indent,
        pageWidth: _options.pageWidth,
        fixes: _options.fixes,
        experimentFlags: _options.experimentFlags);

    try {
      var source = SourceCode(await file.readAsString(), uri: file.path);
      _options.beforeFile(file, displayPath);

      var output = await Isolate.run(() async {
        return formatter.formatSource(source);
      });

      _options.afterFile(file, displayPath, output,
          changed: source.text != output.text);
      return;
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

    // If we get here, some error occurred.
    exitCode = 65;
  }
}
