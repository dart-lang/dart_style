// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import '../calculate_difference.dart';
import '../profile.dart';
import '../source_code.dart';
import 'formatter_options.dart';

/// The kind of summary shown after all formatting is complete.
final class Summary {
  static const Summary none = Summary._();

  /// Creates a Summary that shows the number of lines changed by the formatter.
  static Summary diff() => _DiffSummary();

  /// Creates a Summary that tracks how many files were formatted and the total
  /// time.
  static Summary line() => _LineSummary();

  /// Creates a Summary that captures profiling information.
  ///
  /// Mostly for internal use.
  static Summary profile() => _ProfileSummary();

  const Summary._();

  /// Called when [file] is about to be formatted.
  ///
  /// If stdin is being formatted, then [file] is `null`.
  void beforeFile(File? file, String displayPath) {}

  /// Describe the processed file at [path] whose formatted result is [output].
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  ///
  /// If stdin is being formatted, then [file] is `null`.
  void afterFile(
    FormatterOptions options,
    File? file,
    String displayPath,
    SourceCode input,
    SourceCode output, {
    required bool changed,
  }) {}

  void show() {}
}

/// Tracks how many lines were formatted and how many changed.
final class _DiffSummary extends Summary {
  /// The number of processed files.
  int _files = 0;

  /// The number of changed files.
  int _changed = 0;

  /// The total number of lines of input code.
  int _lines = 0;

  /// The total number of changed lines of code.
  int _changedLines = 0;

  _DiffSummary() : super._();

  /// Describe the processed file at [path] whose formatted result is [output].
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  @override
  void afterFile(
    FormatterOptions options,
    File? file,
    String displayPath,
    SourceCode input,
    SourceCode output, {
    required bool changed,
  }) {
    _files++;
    if (changed) _changed++;

    var inputLines = input.text.split('\n');
    var outputLines = output.text.split('\n');
    _lines += inputLines.length;
    _changedLines += countDifferences(inputLines, outputLines);
  }

  /// Show the times for the slowest files to format.
  @override
  void show() {
    if (_files == 0) {
      print('No files processed.');
      return;
    }

    if (_lines == 0) {
      print('No code processed.');
      return;
    }

    var filePercent = (_changed / _files * 100).toStringAsFixed(2);
    var linePercent = (_changedLines / _lines * 100).toStringAsFixed(2);
    print(
      '$_changed out of $_files files changed ($filePercent%). '
      '$_changedLines out of $_lines lines changed ($linePercent%).',
    );
  }
}

/// Tracks how many files were formatted and the total time.
final class _LineSummary extends Summary {
  final DateTime _start = DateTime.now();

  /// The number of processed files.
  int _files = 0;

  /// The number of changed files.
  int _changed = 0;

  _LineSummary() : super._();

  /// Describe the processed file at [path] whose formatted result is [output].
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  @override
  void afterFile(
    FormatterOptions options,
    File? file,
    String displayPath,
    SourceCode input,
    SourceCode output, {
    required bool changed,
  }) {
    _files++;
    if (changed) _changed++;
  }

  /// Show the times for the slowest files to format.
  @override
  void show() {
    var elapsed = DateTime.now().difference(_start);
    var time = (elapsed.inMilliseconds / 1000).toStringAsFixed(2);

    if (_files == 0) {
      print('Formatted no files in $time seconds.');
    } else if (_files == 1) {
      print('Formatted $_files file ($_changed changed) in $time seconds.');
    } else {
      print('Formatted $_files files ($_changed changed) in $time seconds.');
    }
  }
}

/// Reports how long it took for format each file.
final class _ProfileSummary implements Summary {
  /// The files that have been started but have not completed yet.
  ///
  /// Maps a file label to the time that it started being formatted.
  final Map<String, DateTime> _ongoing = {};

  /// The elapsed time it took to format each completed file.
  final Map<String, Duration> _elapsed = {};

  /// The number of files that completed so fast that they aren't worth
  /// tracking.
  int _elided = 0;

  /// Show the times for the slowest files to format.
  @override
  void show() {
    // Everything should be done.
    assert(_ongoing.isEmpty);

    var files = _elapsed.keys.toList();
    files.sort((a, b) => _elapsed[b]!.compareTo(_elapsed[a]!));

    for (var file in files) {
      print('${_elapsed[file]}: $file');
    }

    if (_elided >= 1) {
      var s = _elided > 1 ? 's' : '';
      print('...$_elided more file$s each took less than 10ms.');
    }

    Profile.report();
  }

  /// Called when [file] is about to be formatted.
  @override
  void beforeFile(File? file, String displayPath) {
    _ongoing[displayPath] = DateTime.now();
  }

  /// Describe the processed file at [path] whose formatted result is [output].
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  @override
  void afterFile(
    FormatterOptions options,
    File? file,
    String displayPath,
    SourceCode input,
    SourceCode output, {
    required bool changed,
  }) {
    var elapsed = DateTime.now().difference(_ongoing.remove(displayPath)!);
    if (elapsed.inMilliseconds >= 10) {
      _elapsed[displayPath] = elapsed;
    } else {
      _elided++;
    }
  }
}
