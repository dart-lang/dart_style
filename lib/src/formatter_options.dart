// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.formatter_options;

import 'dart:convert';
import 'dart:io';

import 'source_code.dart';

/// Global options that affect how the formatter produces and uses its outputs.
class FormatterOptions {
  /// The [OutputReporter] used to show the formatting results.
  final OutputReporter reporter;

  /// The number of columns that formatted output should be constrained to fit
  /// within.
  final int pageWidth;

  /// Whether symlinks should be traversed when formatting a directory.
  final bool followLinks;

  FormatterOptions(this.reporter,
      {this.pageWidth: 80, this.followLinks: false});
}

/// How the formatter reports the results it produces.
abstract class OutputReporter {
  /// Prints only the names of files whose contents are different from their
  /// formatted version.
  static final dryRun = new _DryRunReporter();

  /// Prints the formatted results of each file to stdout.
  static final print = new _PrintReporter();

  /// Prints the formatted result and selection info of each file to stdout as
  /// a JSON map.
  static final printJson = new _PrintJsonReporter();

  /// Overwrites each file with its formatted result.
  static final overwrite = new _OverwriteReporter();

  /// Describe the directory whose contents are about to be processed.
  void showDirectory(String path) {}

  /// Describe the symlink at [path] that wasn't followed.
  void showSkippedLink(String path) {}

  /// Describe the hidden file at [path] that wasn't processed.
  void showHiddenFile(String path) {}

  /// Describe the processed file at [path] whose formatted result is [output].
  ///
  /// If the contents of the file are the same as the formatted output,
  /// [changed] will be false.
  void showFile(File file, String label, SourceCode output, {bool changed});
}

/// Prints only the names of files whose contents are different from their
/// formatted version.
class _DryRunReporter extends OutputReporter {
  void showFile(File file, String label, SourceCode output, {bool changed}) {
    // Only show the changed files.
    if (changed) print(label);
  }
}

/// Prints the formatted results of each file to stdout.
class _PrintReporter extends OutputReporter {
  void showDirectory(String path) {
    print("Formatting directory $path:");
  }

  void showSkippedLink(String path) {
    print("Skipping link $path");
  }

  void showHiddenFile(String path) {
    print("Skipping hidden file $path");
  }

  void showFile(File file, String label, SourceCode output, {bool changed}) {
    // Don't add an extra newline.
    stdout.write(output.text);
  }
}

/// Prints the formatted result and selection info of each file to stdout as a
/// JSON map.
class _PrintJsonReporter extends OutputReporter {
  void showFile(File file, String label, SourceCode output, {bool changed}) {
    // TODO(rnystrom): Put an empty selection in here to remain compatible with
    // the old formatter. Since there's no way to pass a selection on the
    // command line, this will never be used, which is why it's hard-coded to
    // -1, -1. If we add support for passing in a selection, put the real
    // result here.
    print(JSON.encode({
      "path": label,
      "source": output.text,
      "selection": {
        "offset": output.selectionStart != null ? output.selectionStart : -1,
        "length": output.selectionLength != null ? output.selectionLength : -1
      }
    }));
  }
}

/// Overwrites each file with its formatted result.
class _OverwriteReporter extends _PrintReporter {
  void showFile(File file, String label, SourceCode output, {bool changed}) {
    if (changed) {
      file.writeAsStringSync(output.text);
      print("Formatted $label");
    } else {
      print("Unchanged $label");
    }
  }
}
