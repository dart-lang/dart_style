// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../source_code.dart';
import 'output.dart';
import 'show.dart';
import 'summary.dart';

// Note: The following line of code is modified by tool/grind.dart.
const dartStyleVersion = '3.1.2-wip';

/// Global options parsed from the command line that affect how the formatter
/// produces and uses its outputs.
final class FormatterOptions {
  /// The language version formatted code should be parsed at or `null` if not
  /// specified.
  final Version? languageVersion;

  /// The number of spaces of indentation to prefix the output with.
  final int indent;

  /// The number of columns that formatted output should be constrained to fit
  /// within or `null` if not specified.
  ///
  /// If omitted, the formatter defaults to a page width of
  /// [DartFormatter.defaultPageWidth].
  final int? pageWidth;

  /// How trailing commas in the input source code affect formatting.
  final TrailingCommas? trailingCommas;

  /// Whether symlinks should be traversed when formatting a directory.
  final bool followLinks;

  /// Which affected files should be shown.
  final Show show;

  /// Where formatted code should be output.
  final Output output;

  final Summary summary;

  /// Sets the exit code to 1 if any changes are made.
  final bool setExitIfChanged;

  /// Flags to enable experimental language features.
  ///
  /// See dart.dev/go/experiments for details.
  final List<String> experimentFlags;

  FormatterOptions({
    this.languageVersion,
    this.indent = 0,
    this.pageWidth,
    this.trailingCommas,
    this.followLinks = false,
    this.show = Show.changed,
    this.output = Output.write,
    this.summary = Summary.none,
    this.setExitIfChanged = false,
    List<String>? experimentFlags,
  }) : experimentFlags = [...?experimentFlags];

  /// Called when [file] is about to be formatted.
  ///
  /// If stdin is being formatted, then [file] is `null`.
  void beforeFile(File? file, String label) {
    summary.beforeFile(file, label);
  }

  /// Describe the processed file at [path] with formatted [result]s.
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  ///
  /// If stdin is being formatted, then [file] is `null`.
  void afterFile(
    File? file,
    String displayPath,
    SourceCode result, {
    required bool changed,
  }) {
    summary.afterFile(this, file, displayPath, result, changed: changed);

    // Save the results to disc.
    var overwritten = false;
    if (changed) {
      overwritten = output.writeFile(file, displayPath, result);
    }

    // Show the user.
    if (show.file(displayPath, changed: changed, overwritten: overwritten)) {
      output.showFile(displayPath, result);
    }

    // Set the exit code.
    if (setExitIfChanged && changed) exitCode = 1;
  }
}
