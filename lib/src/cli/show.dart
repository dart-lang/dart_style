// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Which file paths should be printed.
enum Show {
  /// No files.
  none,

  /// All traversed files.
  all,

  /// Only files whose formatting changed.
  changed;

  /// Describes a file that was processed.
  ///
  /// Returns whether or not this file should be displayed.
  bool file(String path, {required bool changed, required bool overwritten}) {
    switch (this) {
      case Show.all:
        if (changed) {
          _showFileChange(path, overwritten: overwritten);
        } else {
          print('Unchanged $path');
        }
        return true;

      case Show.changed:
        if (changed) _showFileChange(path, overwritten: overwritten);
        return changed;

      default:
        return true;
    }
  }

  void _showFileChange(String path, {required bool overwritten}) {
    if (overwritten) {
      print('Formatted $path');
    } else {
      print('Changed $path');
    }
  }
}
