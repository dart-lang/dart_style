// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/src/analysis_options/analysis_options_file.dart';
import 'package:dart_style/src/testing/test_file_system.dart';
import 'package:test/test.dart';

import '../utils.dart';

void main() {
  group('findAnalysisOptions()', () {
    test('returns an empty map if no analysis options is found', () async {
      var testFS = TestFileSystem();
      var options =
          await findAnalysisOptions(testFS, TestFileSystemPath('dir|sub'));
      expect(options, isEmpty);
    });

    test('finds a file in the given directory', () async {
      var testFS = TestFileSystem({
        'dir|analysis_options.yaml': analysisOptions(pageWidth: 100),
      });

      var options =
          await findAnalysisOptions(testFS, TestFileSystemPath('dir'));
      expect(_pageWidth(options), equals(100));
    });

    test('stops at the nearest analysis options file', () async {
      var testFS = TestFileSystem({
        'dir|analysis_options.yaml': analysisOptions(pageWidth: 120),
        'dir|sub|analysis_options.yaml': analysisOptions(pageWidth: 100)
      });

      var options =
          await findAnalysisOptions(testFS, TestFileSystemPath('dir|sub'));
      expect(_pageWidth(options), equals(100));
    });

    test('uses the nearest file even if it doesn\'t have the setting',
        () async {
      var testFS = TestFileSystem({
        'dir|analysis_options.yaml': analysisOptions(pageWidth: 120),
        'dir|sub|analysis_options.yaml':
            analysisOptions(other: {'other': 'stuff'})
      });

      var options =
          await findAnalysisOptions(testFS, TestFileSystemPath('dir|sub'));
      expect(_pageWidth(options), isNull);
    });
  });

  group('readAnalysisOptionsOptions()', () {
    test('reads an analysis options file', () async {
      var testFS =
          TestFileSystem({'file.yaml': analysisOptions(pageWidth: 120)});

      var options =
          await readAnalysisOptions(testFS, TestFileSystemPath('file.yaml'));
      expect(_pageWidth(options), 120);
    });

    test('yields an empty map if the file isn\'t a YAML map', () async {
      var testFS = TestFileSystem({'file.yaml': '123'});
      var options =
          await readAnalysisOptions(testFS, TestFileSystemPath('file.yaml'));
      expect(options, isA<Map>());
      expect(options, isEmpty);
    });

    test('merges included files', () async {
      var testFS = TestFileSystem({
        'dir|a.yaml': analysisOptions(include: 'b.yaml', other: {
          'a': 'from a',
          'ab': 'from a',
          'ac': 'from a',
          'abc': 'from a',
          'ad': 'from a',
        }),
        'dir|b.yaml': analysisOptions(include: [
          'c.yaml',
          'd.yaml'
        ], other: {
          'ab': 'from b',
          'abc': 'from b',
          'b': 'from b',
          'bc': 'from b',
          'bd': 'from b',
        }),
        'dir|c.yaml': analysisOptions(other: {
          'ac': 'from c',
          'abc': 'from c',
          'bc': 'from c',
          'c': 'from c',
          'cd': 'from c',
        }),
        'dir|d.yaml': analysisOptions(other: {
          'ad': 'from d',
          'bd': 'from d',
          'cd': 'from d',
        }),
      });

      var options =
          await readAnalysisOptions(testFS, TestFileSystemPath('dir|a.yaml'));
      expect(options['a'], 'from a');
      expect(options['ab'], 'from a');
      expect(options['ac'], 'from a');
      expect(options['ad'], 'from a');
      expect(options['abc'], 'from a');
      expect(options['b'], 'from b');
      expect(options['bc'], 'from b');
      expect(options['bd'], 'from b');
      expect(options['c'], 'from c');
      expect(options['cd'], 'from d');
    });

    test('removes the include key after merging', () async {
      var testFS = TestFileSystem({
        'dir|main.yaml': analysisOptions(pageWidth: 120, include: 'a.yaml'),
        'dir|a.yaml': analysisOptions(other: {'a': 123}),
      });

      var options = await readAnalysisOptions(
          testFS, TestFileSystemPath('dir|main.yaml'));
      expect(options['include'], isNull);
    });

    test('locates includes relative to the parent directory', () async {
      var testFS = TestFileSystem({
        'dir|a.yaml': analysisOptions(include: 'sub|b.yaml', other: {
          'a': 'from a',
        }),
        'dir|sub|b.yaml': analysisOptions(include: 'more|c.yaml', other: {
          'b': 'from b',
        }),
        'dir|sub|more|c.yaml': analysisOptions(other: {
          'c': 'from c',
        }),
      });

      var options =
          await readAnalysisOptions(testFS, TestFileSystemPath('dir|a.yaml'));
      expect(options['a'], 'from a');
      expect(options['b'], 'from b');
      expect(options['c'], 'from c');
    });

    test('resolves "package:" includes', () async {
      var testFS = TestFileSystem({
        'dir|a.yaml':
            analysisOptions(include: 'package:b/b_options.yaml', other: {
          'a': 'from a',
        }),
        '|b|b_options.yaml':
            analysisOptions(include: 'package:c/c_options.yaml', other: {
          'b': 'from b',
        }),
        '|c|c_options.yaml': analysisOptions(other: {
          'c': 'from c',
        }),
      });

      Future<String?> resolve(Uri packageUri) async {
        return '|${packageUri.pathSegments.join('|')}';
      }

      var options = await readAnalysisOptions(
          testFS, TestFileSystemPath('dir|a.yaml'),
          resolvePackageUri: resolve);
      expect(options['a'], 'from a');
      expect(options['b'], 'from b');
      expect(options['c'], 'from c');
    });

    test('throws on a "package:" include with no package resolver', () async {
      var testFS = TestFileSystem({
        'options.yaml': analysisOptions(include: 'package:foo/options.yaml'),
      });

      expect(readAnalysisOptions(testFS, TestFileSystemPath('options.yaml')),
          throwsA(isA<PackageResolutionException>()));
    });

    test('throws on a "package:" resolution failure', () async {
      var testFS = TestFileSystem({
        'options.yaml': analysisOptions(include: 'package:foo/options.yaml'),
      });

      // A resolver that always fails.
      Future<String?> failingResolver(Uri uri) async => null;

      expect(
          readAnalysisOptions(testFS, TestFileSystemPath('options.yaml'),
              resolvePackageUri: failingResolver),
          throwsA(isA<PackageResolutionException>()));
    });
  });
}

/// Reads the `formatter/page_width` key from [options] if present and returns
/// it or `null` if not found.
Object? _pageWidth(AnalysisOptions options) =>
    (options['formatter'] as Map<Object?, Object?>?)?['page_width'];
