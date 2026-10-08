// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import '../utils.dart';

void main() {
  compileFormatter();

  group('given file paths', () {
    test('formats a directory', () async {
      await d.dir('code', [
        d.file('a.dart', unformattedSource),
        d.file('b.dart', formattedSource),
        d.file('c.dart', unformattedSource),
      ]).create();

      var process = await runFormatterOnDir();
      await expectLater(
        process.stdout,
        emitsInOrder([
          'Formatted ${p.join('code', 'a.dart')}',
          'Formatted ${p.join('code', 'c.dart')}',
        ]),
      );
      await expectLater(
        process.stdout,
        emits(startsWith('Formatted 3 files (2 changed)')),
      );
      await process.shouldExit(0);

      // Overwrites the files.
      await d.dir('code', [d.file('a.dart', formattedSource)]).validate();
      await d.dir('code', [d.file('c.dart', formattedSource)]).validate();
    });

    test('formats multiple paths', () async {
      await d.dir('code', [
        d.dir('subdir', [d.file('a.dart', unformattedSource)]),
        d.file('b.dart', unformattedSource),
        d.file('c.dart', unformattedSource),
      ]).create();

      var process = await runFormatter([
        p.join('code', 'subdir'),
        p.join('code', 'c.dart'),
      ]);
      await expectLater(
        process.stdout,
        emitsInOrder([
          'Formatted ${p.join('code', 'subdir', 'a.dart')}',
          'Formatted ${p.join('code', 'c.dart')}',
        ]),
      );
      await expectLater(
        process.stdout,
        emits(startsWith('Formatted 2 files (2 changed)')),
      );
      await process.shouldExit(0);

      // Overwrites the selected files.
      await d.dir('code', [
        d.dir('subdir', [d.file('a.dart', formattedSource)]),
        d.file('b.dart', unformattedSource),
        d.file('c.dart', formattedSource),
      ]).validate();
    });
  });

  test('exits with 64 on a command line argument error', () async {
    var process = await runFormatter(['-wat']);
    await process.shouldExit(64);
  });

  test('exits with 65 on a parse error', () async {
    await d.dir('code', [d.file('a.dart', 'herp derp i are a dart')]).create();

    var process = await runFormatterOnDir();
    await process.shouldExit(65);
  });

  test('--version prints the version number', () async {
    var process = await runFormatter(['--version']);

    // Match something roughly semver-like.
    await expectLater(
      process.stdout,
      emits(matches(RegExp(r'\d+\.\d+\.\d+.*'))),
    );
    await process.shouldExit(0);
  });

  group('--help', () {
    test('non-verbose shows description and common options', () async {
      var process = await runFormatter(['--help']);
      await expectLater(
        process.stdout,
        emits('Idiomatically format Dart source code.'),
      );
      await expectLater(process.stdout, emitsThrough(contains('-o, --output')));
      await expectLater(process.stdout, neverEmits(contains('--summary')));
      await process.shouldExit(0);
    });

    test('verbose shows description and all options', () async {
      var process = await runFormatter(['--help', '--verbose']);
      await expectLater(
        process.stdout,
        emits('Idiomatically format Dart source code.'),
      );
      await expectLater(process.stdout, emitsThrough(contains('-o, --output')));
      await expectLater(process.stdout, emitsThrough(contains('--show')));
      await expectLater(process.stdout, emitsThrough(contains('--summary')));
      await process.shouldExit(0);
    });
  });

  test('--verbose errors if not used with --help', () async {
    var process = await runFormatterOnDir(['--verbose']);
    expect(await process.stderr.next, 'Can only use --verbose with --help.');
    await process.shouldExit(64);
  });

  group('--indent', () {
    test('sets the leading indentation of the output', () async {
      var process = await runFormatter(['--indent=3']);
      process.stdin.writeln("main() {'''");
      process.stdin.writeln("a flush left multi-line string''';}");
      await process.stdin.close();

      await expectLater(
        process.stdout,
        emitsInOrder([
          '   main() {',
          "     '''",
          "a flush left multi-line string''';",
          '   }',
        ]),
      );
      await process.shouldExit(0);
    });

    test('errors if the indent is not a non-negative number', () async {
      var process = await runFormatter(['--indent=notanum']);
      await process.shouldExit(64);

      process = await runFormatter(['--indent=-4']);
      await process.shouldExit(64);
    });
  });

  group('--set-exit-if-changed', () {
    test('gives exit code 0 if there are no changes', () async {
      await d.dir('code', [d.file('a.dart', formattedSource)]).create();

      var process = await runFormatterOnDir(['--set-exit-if-changed']);
      await process.shouldExit(0);
    });

    test('gives exit code 1 if there are changes', () async {
      await d.dir('code', [d.file('a.dart', unformattedSource)]).create();

      var process = await runFormatterOnDir(['--set-exit-if-changed']);
      await process.shouldExit(1);
    });

    test('gives exit code 1 if there are changes when not writing', () async {
      await d.dir('code', [d.file('a.dart', unformattedSource)]).create();

      var process = await runFormatterOnDir([
        '--set-exit-if-changed',
        '--show=none',
      ]);
      await process.shouldExit(1);
    });
  });

  group('--selection', () {
    test('errors if given path', () async {
      var process = await runFormatter(['--selection', 'path']);
      await process.shouldExit(64);
    });

    test('errors on wrong number of components', () async {
      var process = await runFormatter(['--selection', '1']);
      await process.shouldExit(64);

      process = await runFormatter(['--selection', '1:2:3']);
      await process.shouldExit(64);
    });

    test('errors on non-integer component', () async {
      var process = await runFormatter(['--selection', '1:2.3']);
      await process.shouldExit(64);
    });

    test('updates selection', () async {
      var process = await runFormatter(['--output=json', '--selection=6:10']);
      process.stdin.writeln(unformattedSource);
      await process.stdin.close();

      var json = jsonEncode({
        'path': 'stdin',
        'source': formattedSource,
        'selection': {'offset': 5, 'length': 9},
      });

      await expectLater(process.stdout, emits(json));
      await process.shouldExit();
    });

    test('works with --stdin-name', () async {
      var process = await runFormatter([
        '--output=json',
        '--selection=6:10',
        '--stdin-name=foo',
      ]);
      process.stdin.writeln(unformattedSource);
      await process.stdin.close();

      var json = jsonEncode({
        'path': 'foo',
        'source': formattedSource,
        'selection': {'offset': 5, 'length': 9},
      });

      await expectLater(process.stdout, emits(json));
      await process.shouldExit();
    });
  });
}
