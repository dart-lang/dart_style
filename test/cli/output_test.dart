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

  group('--show', () {
    test('all shows all files', () async {
      await d.dir('code', [
        d.file('a.dart', unformattedSource),
        d.file('b.dart', formattedSource),
        d.file('c.dart', unformattedSource),
      ]).create();

      var process = await runFormatterOnDir(['--show=all']);
      await expectLater(
        process.stdout,
        emitsInOrder([
          'Formatted ${p.join('code', 'a.dart')}',
          'Unchanged ${p.join('code', 'b.dart')}',
          'Formatted ${p.join('code', 'c.dart')}',
        ]),
      );
      await expectLater(
        process.stdout,
        emits(startsWith('Formatted 3 files (2 changed)')),
      );
      await process.shouldExit(0);
    });

    test('none shows nothing', () async {
      await d.dir('code', [
        d.file('a.dart', unformattedSource),
        d.file('b.dart', formattedSource),
        d.file('c.dart', unformattedSource),
      ]).create();

      var process = await runFormatterOnDir(['--show=none']);
      await expectLater(
        process.stdout,
        emits(startsWith('Formatted 3 files (2 changed)')),
      );
      await process.shouldExit(0);
    });

    test('changed shows changed files', () async {
      await d.dir('code', [
        d.file('a.dart', unformattedSource),
        d.file('b.dart', formattedSource),
        d.file('c.dart', unformattedSource),
      ]).create();

      var process = await runFormatterOnDir(['--show=changed']);
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
    });
  });

  group('--output', () {
    group('show', () {
      test('prints only formatted output by default', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', formattedSource),
        ]).create();

        var process = await runFormatterOnDir(['--output=show']);
        await expectLater(
          process.stdout,
          emitsInOrder([formattedOutput, formattedOutput]),
        );
        await expectLater(
          process.stdout,
          emits(startsWith('Formatted 2 files (1 changed)')),
        );
        await process.shouldExit(0);

        // Does not overwrite files.
        await d.dir('code', [d.file('a.dart', unformattedSource)]).validate();
      });

      test('with --show=all prints all files and names first', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', formattedSource),
        ]).create();

        var process = await runFormatterOnDir(['--output=show', '--show=all']);
        await expectLater(
          process.stdout,
          emitsInOrder([
            'Changed ${p.join('code', 'a.dart')}',
            formattedOutput,
            'Unchanged ${p.join('code', 'b.dart')}',
            formattedOutput,
          ]),
        );
        await expectLater(
          process.stdout,
          emits(startsWith('Formatted 2 files (1 changed)')),
        );
        await process.shouldExit(0);

        // Does not overwrite files.
        await d.dir('code', [d.file('a.dart', unformattedSource)]).validate();
      });

      test('with --show=changed prints only changed files', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', formattedSource),
        ]).create();

        var process = await runFormatterOnDir([
          '--output=show',
          '--show=changed',
        ]);
        await expectLater(
          process.stdout,
          emitsInOrder([
            'Changed ${p.join('code', 'a.dart')}',
            formattedOutput,
          ]),
        );
        await expectLater(
          process.stdout,
          emits(startsWith('Formatted 2 files (1 changed)')),
        );
        await process.shouldExit(0);

        // Does not overwrite files.
        await d.dir('code', [d.file('a.dart', unformattedSource)]).validate();
      });
    });

    group('json', () {
      test('writes each output as json', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', unformattedSource),
        ]).create();

        var jsonA = jsonEncode({
          'path': p.join('code', 'a.dart'),
          'source': formattedSource,
          'selection': {'offset': -1, 'length': -1},
        });

        var jsonB = jsonEncode({
          'path': p.join('code', 'b.dart'),
          'source': formattedSource,
          'selection': {'offset': -1, 'length': -1},
        });

        var process = await runFormatterOnDir(['--output=json']);

        await expectLater(process.stdout, emitsInOrder([jsonA, jsonB]));
        await process.shouldExit();
      });

      test('errors if the summary is not none', () async {
        var process = await runFormatterOnDir([
          '--output=json',
          '--summary=line',
        ]);
        await process.shouldExit(64);
      });
    });

    group('none', () {
      test('with --show=all prints only names', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', formattedSource),
        ]).create();

        var process = await runFormatterOnDir(['--output=none', '--show=all']);
        await expectLater(
          process.stdout,
          emitsInOrder([
            'Changed ${p.join('code', 'a.dart')}',
            'Unchanged ${p.join('code', 'b.dart')}',
          ]),
        );
        await expectLater(
          process.stdout,
          emits(startsWith('Formatted 2 files (1 changed)')),
        );
        await process.shouldExit(0);

        // Does not overwrite files.
        await d.dir('code', [d.file('a.dart', unformattedSource)]).validate();
      });

      test('with --show=changed prints only changed names', () async {
        await d.dir('code', [
          d.file('a.dart', unformattedSource),
          d.file('b.dart', formattedSource),
        ]).create();

        var process = await runFormatterOnDir([
          '--output=none',
          '--show=changed',
        ]);
        await expectLater(
          process.stdout,
          emits('Changed ${p.join('code', 'a.dart')}'),
        );
        await expectLater(
          process.stdout,
          emits(startsWith('Formatted 2 files (1 changed)')),
        );
        await process.shouldExit(0);

        // Does not overwrite files.
        await d.dir('code', [d.file('a.dart', unformattedSource)]).validate();
      });
    });
  });

  group('--summary', () {
    test('line', () async {
      await d.dir('code', [
        d.file('a.dart', unformattedSource),
        d.file('b.dart', formattedSource),
      ]).create();

      var process = await runFormatterOnDir(['--summary=line']);
      await expectLater(
        process.stdout,
        emits('Formatted ${p.join('code', 'a.dart')}'),
      );
      await expectLater(
        process.stdout,
        emits(matches(r'Formatted 2 files \(1 changed\) in \d+\.\d+ seconds.')),
      );
      await process.shouldExit(0);
    });
  });
}
