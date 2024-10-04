// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_system.dart';

/// An implementation of [FileSystem] using `dart:io`.
class IOFileSystem implements FileSystem {
  Future<IOFileSystemPath> makePath(String path) async =>
      IOFileSystemPath._(path);

  @override
  Future<bool> fileExists(FileSystemPath path) => File(path.ioPath).exists();

  @override
  Future<FileSystemPath> join(FileSystemPath from, String to) =>
      makePath(p.join(from.ioPath, to));

  @override
  Future<FileSystemPath?> parentDirectory(FileSystemPath path) async {
    // Make [path] absolute (if not already) so that we can walk outside of the
    // literal path string passed.
    var result = p.dirname(p.absolute(path.ioPath));

    // If the parent directory is the same as [path], we must be at the root.
    if (result == path.ioPath) return null;

    return makePath(result);
  }

  @override
  Future<String> readFile(FileSystemPath path) =>
      File(path.ioPath).readAsString();
}

/// An abstraction over a file path string, used by [IOFileSystem].
///
/// To create an instance of this, use [IOFileSystem.makePath()].
class IOFileSystemPath implements FileSystemPath {
  /// The underlying physical file system path.
  final String path;

  IOFileSystemPath._(this.path);
}

extension on FileSystemPath {
  String get ioPath => (this as IOFileSystemPath).path;
}
