// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../analysis_options/file_system.dart';

/// A simulated file system for tests.
///
/// Uses `|` as directory separator to make sure that the implementating code
/// calling into this doesn't assume a directory separator character.
class TestFileSystem implements FileSystem {
  final Map<String, String> _files = {};

  TestFileSystem([Map<String, String>? files]) {
    if (files != null) _files.addAll(files);
  }

  @override
  Future<bool> fileExists(FileSystemPath path) async =>
      _files.containsKey(path.testPath);

  @override
  Future<FileSystemPath> join(FileSystemPath from, String to) async {
    return TestFileSystemPath('${from.testPath}|$to');
  }

  @override
  Future<FileSystemPath?> parentDirectory(FileSystemPath path) async {
    var parts = path.testPath.split('|');
    if (parts.length == 1) return null;

    return TestFileSystemPath(parts.sublist(0, parts.length - 1).join('|'));
  }

  @override
  Future<String> readFile(FileSystemPath path) async {
    if (_files[path.testPath] case var contents?) return contents;
    throw Exception('No file at "$path".');
  }
}

class TestFileSystemPath implements FileSystemPath {
  final String _path;

  TestFileSystemPath(this._path);

  @override
  String toString() => _path;
}

extension on FileSystemPath {
  String get testPath => (this as TestFileSystemPath)._path;
}
