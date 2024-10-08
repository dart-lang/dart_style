// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../analysis_options/file_system.dart';

/// A simulated file system for tests.
///
/// Uses `|` as directory separator to make sure that the implementating code
/// calling into this doesn't assume a directory separator character.
///
/// A path starting with `|` is considered absolute for purposes of joining.
final class TestFileSystem implements FileSystem {
  final Map<String, String> _files = {};

  TestFileSystem([Map<String, String>? files]) {
    if (files != null) _files.addAll(files);
  }

  @override
  Future<bool> fileExists(covariant TestFileSystemPath path) async =>
      _files.containsKey(path._path);

  @override
  Future<FileSystemPath> join(
      covariant TestFileSystemPath from, String to) async {
    // If it's an absolute path, discard [from].
    if (to.startsWith('|')) return TestFileSystemPath(to);
    return TestFileSystemPath('${from._path}|$to');
  }

  @override
  Future<FileSystemPath?> parentDirectory(
      covariant TestFileSystemPath path) async {
    var parts = path._path.split('|');
    if (parts.length == 1) return null;

    return TestFileSystemPath(parts.sublist(0, parts.length - 1).join('|'));
  }

  @override
  Future<String> readFile(covariant TestFileSystemPath path) async {
    if (_files[path._path] case var contents?) return contents;
    throw Exception('No file at "$path".');
  }
}

final class TestFileSystemPath implements FileSystemPath {
  final String _path;

  TestFileSystemPath(this._path);

  @override
  String toString() => _path;
}
