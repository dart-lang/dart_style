// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_system.dart';

/// An implementation of [FileSystem] using `dart:io`.
final class IOFileSystem implements FileSystem {
  Future<IOFileSystemPath> makePath(String path) async =>
      IOFileSystemPath._(path);

  @override
  Future<bool> fileExists(covariant IOFileSystemPath path) =>
      File(path.path).exists();

  @override
  Future<FileSystemPath> join(covariant IOFileSystemPath from, String to) =>
      makePath(p.join(from.path, to));

  @override
  Future<FileSystemPath?> parentDirectory(
      covariant IOFileSystemPath path) async {
    // Make [path] absolute (if not already) so that we can walk outside of the
    // literal path string passed.
    var result = p.dirname(p.absolute(path.path));

    // If the parent directory is the same as [path], we must be at the root.
    if (result == path.path) return null;

    return makePath(result);
  }

  @override
  Future<String> readFile(covariant IOFileSystemPath path) =>
      File(path.path).readAsString();
}

/// An abstraction over a file path string, used by [IOFileSystem].
///
/// To create an instance of this, use [IOFileSystem.makePath()].
final class IOFileSystemPath implements FileSystemPath {
  /// The underlying physical file system path.
  final String path;

  IOFileSystemPath._(this.path);
}
