// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/src/analysis_options/file_system.dart';
import 'package:dart_style/src/analysis_options/io_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('makePath()', () {
    test('creates a relative path', () async {
      var fs = IOFileSystem();
      expect(
          (await fs.makePath('relative/path.txt')).path, 'relative/path.txt');
    });

    test('creates an absolute path', () async {
      var fs = IOFileSystem();
      var absolutePath = p.style == p.Style.posix ? '/abs' : 'C:\\abs';
      expect((await fs.makePath(absolutePath)).path, absolutePath);
    });
  });

  group('fileExists()', () {
    test('returns whether a file exists at that path', () async {
      await d.dir('dir', [
        d.file('exists.txt', 'contents'),
      ]).create();

      var fs = IOFileSystem();
      expect(
          await fs.fileExists(
              await fs.makePath(p.join(d.sandbox, 'dir', 'exists.txt'))),
          isTrue);
      expect(
          await fs.fileExists(
              await fs.makePath(p.join(d.sandbox, 'dir', 'nope.txt'))),
          isFalse);
    });

    test('returns false if the entry at that path is not a file', () async {
      await d.dir('dir', [
        d.dir('sub', []),
      ]).create();

      var fs = IOFileSystem();
      expect(
          await fs
              .fileExists(await fs.makePath(p.join(d.sandbox, 'dir', 'sub'))),
          isFalse);
    });
  });

  group('join()', () {
    test('joins paths', () async {
      var fs = IOFileSystem();
      expect((await fs.join(await fs.makePath('dir'), 'file.txt')).ioPath,
          p.join('dir', 'file.txt'));
    });

    test('joins an absolute path', () async {
      var fs = IOFileSystem();

      var absolutePath = p.style == p.Style.posix ? '/abs' : 'C:\\abs';
      expect((await fs.join(await fs.makePath('dir'), absolutePath)).ioPath,
          absolutePath);
    });
  });

  group('parentDirectory()', () {
    var fs = IOFileSystem();

    // Wrap [path] in an IOFileSystemPath, get the parent directory, and unwrap
    // the result (which might be null).
    Future<String?> parent(String path) async =>
        (await fs.parentDirectory(await fs.makePath(path))).ioPath;

    test('returns the containing directory', () async {
      expect(await parent(p.join('dir', 'sub', 'file.txt')),
          p.absolute(p.join('dir', 'sub')));

      expect(await parent(p.join('dir', 'sub')), p.absolute(p.join('dir')));
    });

    test('returns null at the root directory (POSIX)', () async {
      var rootPath = p.style == p.Style.posix ? '/' : 'C:\\';
      expect(await parent(rootPath), null);
    });
  });

  group('readFile()', () {
    test('reads a file', () async {
      await d.dir('dir', [
        d.file('some_file.txt', 'contents'),
        d.dir('sub', [
          d.file('another.txt', 'more'),
        ]),
      ]).create();

      var fs = IOFileSystem();
      expect(
          await fs.readFile(
              await fs.makePath(p.join(d.sandbox, 'dir', 'some_file.txt'))),
          'contents');
      expect(
          await fs.readFile(await fs
              .makePath(p.join(d.sandbox, 'dir', 'sub', 'another.txt'))),
          'more');
    });

    test('treats relative paths as relative to the CWD', () async {
      await d.dir('dir', [
        d.file('some_file.txt', 'contents'),
        d.dir('sub', [
          d.file('another.txt', 'more'),
        ]),
      ]).create();

      var fs = IOFileSystem();
      expect(
          await fs.readFile(
              await fs.makePath(p.join(d.sandbox, 'dir', 'some_file.txt'))),
          'contents');
      expect(
          await fs.readFile(await fs
              .makePath(p.join(d.sandbox, 'dir', 'sub', 'another.txt'))),
          'more');
    });
  });
}

extension on FileSystemPath? {
  String? get ioPath => (this as IOFileSystemPath?)?.path;
}
