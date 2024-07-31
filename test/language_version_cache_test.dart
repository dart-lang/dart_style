// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:dart_style/src/language_version_cache.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'utils.dart';

const _source = 'f() {}';

void main() {
  test('no surrounding package config', () async {
    // Note: In theory this test could fail if machine it's run on happens to
    // have a `.dart_tool` directory containing a package config in one of the
    // parent directories of the system temporary directory.

    await d.dir('dir', [d.file('main.dart', _source)]).create();

    var cache = LanguageVersionCache();
    await _expectNullVersion(cache, 'dir/main.dart');
  });

  test('language version from package config', () async {
    await d.dir('foo', [
      packageConfig('foo', 3, 4),
      d.file('main.dart', _source),
    ]).create();

    var cache = LanguageVersionCache();
    await _expectVersion(cache, 'foo/main.dart', 3, 4);
  });

  test('multiple packages in directory', () async {
    await d.dir('parent', [
      _makePackage('foo', 3, 4),
      _makePackage('bar', 3, 5),
    ]).create();

    var cache = LanguageVersionCache();
    await _expectVersion(cache, 'parent/foo/main.dart', 3, 4);
    await _expectVersion(cache, 'parent/bar/main.dart', 3, 5);
  });

  test('multiple files in same package', () async {
    await _makePackage('foo', 3, 4, [
      d.file('main.dart', _source),
      d.dir('sub', [
        d.file('another.dart', _source),
        d.dir('further', [
          d.file('third.dart', _source),
        ]),
      ]),
    ]).create();

    var cache = LanguageVersionCache();
    await _expectVersion(cache, 'foo/main.dart', 3, 4);
    await _expectVersion(cache, 'foo/sub/another.dart', 3, 4);
    await _expectVersion(cache, 'foo/sub/further/third.dart', 3, 4);
  });

  test('some files in package, some not', () async {
    await d.dir('parent', [
      _makePackage('foo', 3, 4),
      d.file('outside.dart', _source),
      d.dir('sub', [
        d.file('another.dart', _source),
      ]),
    ]).create();

    var cache = LanguageVersionCache();
    await _expectVersion(cache, 'parent/foo/main.dart', 3, 4);
    await _expectNullVersion(cache, 'parent/outside.dart');
    await _expectNullVersion(cache, 'parent/sub/another.dart');
  });

  test('non-existent file', () async {
    await d.dir('dir', []).create();

    var cache = LanguageVersionCache();
    await _expectNullVersion(cache, 'dir/does_not_exist.dart');
  });

  test('non-existent directory', () async {
    await d.dir('dir', []).create();

    var cache = LanguageVersionCache();
    await _expectNullVersion(cache, 'dir/does/not/exist.dart');
  });

  test('nested package', () async {
    await _makePackage('outer', 3, 4, [
      d.file('out_main.dart', _source),
      _makePackage('inner', 3, 5, [
        d.file('in_main.dart', _source),
      ])
    ]).create();

    var cache = LanguageVersionCache();
    await _expectVersion(cache, 'outer/out_main.dart', 3, 4);
    await _expectVersion(cache, 'outer/inner/in_main.dart', 3, 5);
  });
}

Future<void> _expectVersion(
    LanguageVersionCache cache, String path, int major, int minor) async {
  expect(await cache.find(_expectedFile(path)), Version(major, minor, 0));
}

Future<void> _expectNullVersion(LanguageVersionCache cache, String path) async {
  expect(await cache.find(_expectedFile(path)), null);
}

/// Normalize path separators to the host OS separator since that's what the
/// cache uses.
File _expectedFile(String path) => File(
      p.joinAll([d.sandbox, ...p.posix.split(path)]),
    );

/// Create a test package with [packageName] containing a package config with
/// language version [major].[minor].
///
/// If [files] is given, then the package contains those files, otherwise it
/// contains a default `main.dart` file.
d.DirectoryDescriptor _makePackage(
  String packageName,
  int major,
  int minor, [
  List<d.Descriptor>? files,
]) {
  files ??= [d.file('main.dart', _source)];
  return d.dir(packageName, [
    packageConfig(packageName, major, minor),
    ...files,
  ]);
}
