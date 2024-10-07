// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Abstraction over a file system.
///
/// Implement this if you want to control how this package locates and reads
/// files.
abstract interface class FileSystem {
  /// Returns `true` if there is a file at [path].
  Future<bool> fileExists(covariant FileSystemPath path);

  /// Joins [from] and [to] into a single path with appropriate path separators.
  ///
  /// Note that [to] may be an absolute path implementation of [join()] should
  /// be prepared to handle that by ignoring [from].
  Future<FileSystemPath> join(covariant FileSystemPath from, String to);

  /// Returns a path for the directory containing [path].
  ///
  /// If [path] is a root path, then returns `null`.
  Future<FileSystemPath?> parentDirectory(covariant FileSystemPath path);

  /// Returns the series of directories surrounding [path], from innermost out.
  ///
  /// If [path] is itself a directory, then it should be the first directory
  /// yielded by this. Otherwise, the stream should begin with the directory
  /// containing that file.
  // Stream<FileSystemPath> parentDirectories(FileSystemPath path);

  /// Reads the contents of the file as [path], which should exist and contain
  /// UTF-8 encoded text.
  Future<String> readFile(covariant FileSystemPath path);
}

/// Abstraction over a file or directory in a [FileSystem].
///
/// An implementation of [FileSystem] should have a corresponding implementation
/// of this class. It can safely assume that any instances of this passed in to
/// the class were either directly created as instances of the implementation
/// class by the host application, or were returned by methods on that same
/// [FileSystem] object. Thus it is safe for an implementation of [FileSystem]
/// to downcast instances of this to its expected implementation type.
abstract interface class FileSystemPath {}
