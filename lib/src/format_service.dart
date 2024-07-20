// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cli/formatter_options.dart';
import 'debug.dart' as debug;
import 'profile.dart';
import 'source_code.dart';
import 'worker.dart';

class FormatService {
  final FormatterOptions _options;

  // TODO: Get rid of this field?
  final List<Worker> _workers = [];

  final Queue<(File, String)> _files = Queue();

  final Completer<void> _done = Completer();

  int _totalFiles = 0;
  int _completedFiles = 0;

  FormatService(this._options);

  /// Formats all of the files and directories given by [paths].
  Future<void> format(List<String> paths) async {
    Profile.begin2('FormatService.format()');

    Profile.begin2('list paths');
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
    Profile.end2('list paths');

    Profile.begin2('read files');
    for (var file in files) {
      _files.add((file, await file.readAsString()));
    }

    _totalFiles = _files.length;
    Profile.end2('read files');

    Profile.begin2('start workers');
    await _start();
    Profile.end2('start workers');

    Profile.begin2('format everything');

    // TODO: This is wrong if there are more workers than files.
    // Kick off every worker.
    for (var i = 0; i < _workers.length; i++) {
      unawaited(_formatNextFile(_workers[i]));
    }

    await _done.future;

    Profile.end2('format everything');

    Profile.begin2('quit workers');
    await _quit();
    Profile.end2('quit workers');

    Profile.end2('FormatService.format()');
    Profile.report();
  }

  Future<void> _formatNextFile(Worker worker) async {
    if (_files.isEmpty) return;

    var (file, source) = _files.removeFirst();

    if (debug.traceWorkers) {
      debug.log('FormatService._formatNextFile(${file.path})');
    }

    Profile.begin2('request and wait for format', file.path);
    var response = await worker.requestFormat(_options, file.path, source);
    Profile.end2('request and wait for format', file.path);

    // TODO: Should be displayPath instead of file.path.
    var output = SourceCode(response.text,
        uri: file.path,
        selectionStart: response.selectionStart,
        selectionLength: response.selectionLength);
    _options.afterFile(file, file.path, output, changed: source != output.text);

    _completedFiles++;

    if (_files.isNotEmpty) {
      // There are more files to process, so take the next one.
      unawaited(_formatNextFile(worker));
    } else if (_completedFiles == _totalFiles) {
      // The last file is done, so we're done.
      _done.complete();
    }

    // Otherwise, there are no more files to process but we need to wait for
    // the rest of the workers to finish formatting their last file, so do
    // nothing and let this worker idle.
    // TODO: Quit the worker here?
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

  Future<void> _start() async {
    // TODO: CLI option to control number of workers.
    var count = Platform.numberOfProcessors;
    for (var i = 1; i <= count; i++) {
      var worker = await Worker.start(i);
      _workers.add(worker);
    }
  }

  Future<void> _quit() async {
    for (var worker in _workers) {
      worker.quit();
    }
  }
}
