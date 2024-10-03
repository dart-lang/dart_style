// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:convert';
import 'dart:io';

import 'package:dart_style/src/config_cache.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'utils.dart';

void main() {
  group('findLanguageVersion()', () {
    test('no surrounding package config', () async {
      // Note: In theory this test could fail if machine it's run on happens to
      // have a `.dart_tool` directory containing a package config in one of the
      // parent directories of the system temporary directory.

      await d.dir('dir', [d.file('main.dart', 'f() {}')]).create();

      var cache = ConfigCache();
      await _expectNullVersion(cache, 'dir/main.dart');
    });

    test('language version from package config', () async {
      await d.dir('foo', [
        packageConfig('foo', version: '3.4'),
        d.file('main.dart', 'f() {}'),
      ]).create();

      var cache = ConfigCache();
      await _expectVersion(cache, 'foo/main.dart', 3, 4);
    });

    test('multiple packages in directory', () async {
      await d.dir('parent', [
        _makePackage('foo', '3.4'),
        _makePackage('bar', '3.5'),
      ]).create();

      var cache = ConfigCache();
      await _expectVersion(cache, 'parent/foo/main.dart', 3, 4);
      await _expectVersion(cache, 'parent/bar/main.dart', 3, 5);
    });

    test('multiple files in same package', () async {
      await _makePackage('foo', '3.4', [
        d.file('main.dart', 'f() {}'),
        d.dir('sub', [
          d.file('another.dart', 'f() {}'),
          d.dir('further', [
            d.file('third.dart', 'f() {}'),
          ]),
        ]),
      ]).create();

      var cache = ConfigCache();
      await _expectVersion(cache, 'foo/main.dart', 3, 4);
      await _expectVersion(cache, 'foo/sub/another.dart', 3, 4);
      await _expectVersion(cache, 'foo/sub/further/third.dart', 3, 4);
    });

    test('some files in package, some not', () async {
      await d.dir('parent', [
        _makePackage('foo', '3.4'),
        d.file('outside.dart', 'f() {}'),
        d.dir('sub', [
          d.file('another.dart', 'f() {}'),
        ]),
      ]).create();

      var cache = ConfigCache();
      await _expectVersion(cache, 'parent/foo/main.dart', 3, 4);
      await _expectNullVersion(cache, 'parent/outside.dart');
      await _expectNullVersion(cache, 'parent/sub/another.dart');
    });

    test('non-existent file', () async {
      await d.dir('dir', []).create();

      var cache = ConfigCache();
      await _expectNullVersion(cache, 'dir/does_not_exist.dart');
    });

    test('non-existent directory', () async {
      await d.dir('dir', []).create();

      var cache = ConfigCache();
      await _expectNullVersion(cache, 'dir/does/not/exist.dart');
    });

    test('nested package', () async {
      await _makePackage('outer', '3.4', [
        d.file('out_main.dart', 'f() {}'),
        _makePackage('inner', '3.5', [
          d.file('in_main.dart', 'f() {}'),
        ])
      ]).create();

      var cache = ConfigCache();
      await _expectVersion(cache, 'outer/out_main.dart', 3, 4);
      await _expectVersion(cache, 'outer/inner/in_main.dart', 3, 5);
    });
  });

  group('findPageWidth()', () {
    test('null page width if no surrounding options', () async {
      await d.dir('dir', [
        d.file('main.dart', 'main() {}'),
      ]).create();

      var cache = ConfigCache();
      expect(await cache.findPageWidth(_expectedFile('dir/main.dart')), isNull);
    });

    test('use page width of surrounding options', () async {
      await d.dir('dir', [
        analysisOptionsFile(pageWidth: 20),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: 20);
    });

    test('use page width of indirectly surrounding options', () async {
      await d.dir('dir', [
        analysisOptionsFile(pageWidth: 30),
        d.dir('some', [
          d.dir('sub', [
            d.dir('directory', [
              d.file('main.dart', 'f() {}'),
            ]),
          ]),
        ]),
      ]).create();

      await _expectWidth(file: 'dir/some/sub/directory/main.dart', width: 30);
    });

    test('null page width if no "formatter" key in options', () async {
      await d.dir('dir', [
        d.FileDescriptor(
          'analysis_options.yaml',
          jsonEncode({'unrelated': 'stuff'}),
        ),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: null);
    });

    test('null page width if "formatter" is not a map', () async {
      await d.dir('dir', [
        d.FileDescriptor(
          'analysis_options.yaml',
          jsonEncode({'formatter': 'not a map'}),
        ),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: null);
    });

    test('null page width if no "page_width" key in formatter', () async {
      await d.dir('dir', [
        d.FileDescriptor(
          'analysis_options.yaml',
          jsonEncode({
            'formatter': {'no': 'page_width'}
          }),
        ),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: null);
    });

    test('null page width if no "page_width" not an int', () async {
      await d.dir('dir', [
        d.FileDescriptor(
          'analysis_options.yaml',
          jsonEncode({
            'formatter': {'page_width': 'not an int'}
          }),
        ),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: null);
    });

    test('take page width from included options file', () async {
      await d.dir('dir', [
        analysisOptionsFile(include: 'other.yaml'),
        analysisOptionsFile(name: 'other.yaml', include: 'sub/third.yaml'),
        d.dir('sub', [
          analysisOptionsFile(name: 'third.yaml', pageWidth: 30),
        ]),
        d.file('main.dart', 'main() {}'),
      ]).create();

      await _expectWidth(width: 30);
    });
  });
}

Future<void> _expectVersion(
    ConfigCache cache, String path, int major, int minor) async {
  expect(await cache.findLanguageVersion(_expectedFile(path), path),
      Version(major, minor, 0));
}

Future<void> _expectNullVersion(ConfigCache cache, String path) async {
  expect(await cache.findLanguageVersion(_expectedFile(path), path), null);
}

/// Test that a [file] with some some surrounding analysis_options.yaml is
/// interpreted as having the given page [width].
Future<void> _expectWidth(
    {String file = 'dir/main.dart', required int? width}) async {
  var cache = ConfigCache();
  expect(await cache.findPageWidth(_expectedFile(file)), width);
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
  String version, [
  List<d.Descriptor>? files,
]) {
  files ??= [d.file('main.dart', 'f() {}')];
  return d.dir(packageName, [
    packageConfig(packageName, version: version),
    ...files,
  ]);
}
