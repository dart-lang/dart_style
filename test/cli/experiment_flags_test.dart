// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '../utils.dart';

void main() {
  compileFormatter();

  // TODO(rnystrom): At some point, this should test that the formatter also
  // has access to these same experiment flags. But currently, the formatter
  // doesn't use experiment flags for anything, so there is nothing to test
  // and no way to test it.

  group('reads flags from analysis_options.yaml file', () {
    test('when reading from paths', () async {
      await d.dir('foo', [
        analysisOptionsFile(experimentFlags: ['variance']),
        d.file('main.dart', 'class Writer<in T> {}\n'),
      ]).create();

      var process = await runFormatterOnDir();

      await _expectParseButNotFormat(process);
    });

    test('when reading from stdin with --stdin-name', () async {
      await d.dir('foo', [
        analysisOptionsFile(experimentFlags: ['variance']),
      ]).create();

      var process = await runFormatter(['--stdin-name=foo/main.dart']);
      process.stdin.writeln('class Writer<in T> {}');
      await process.stdin.close();

      await _expectParseButNotFormat(process);
    });
  });

  group('--enable-experiment', () {
    group('passes experiment flags to parser', () {
      test('when reading from paths', () async {
        await d.file('main.dart', 'class Writer<in T> {}\n').create();
        var process = await runFormatterOnDir(['--enable-experiment=variance']);

        await _expectParseButNotFormat(process);
      });

      test('when reading from stdin', () async {
        var process = await runFormatter(['--enable-experiment=variance']);
        process.stdin.writeln('class Writer<in T> {}');
        await process.stdin.close();

        await _expectParseButNotFormat(process);
      });

      test('when reading from stdin with --stdin-name', () async {
        var process = await runFormatter([
          '--enable-experiment=variance',
          '--stdin-name=foo',
        ]);
        process.stdin.writeln('class Writer<in T> {}');
        await process.stdin.close();

        await _expectParseButNotFormat(process);
      });
    });

    test('replaces flags from analysis_options.yaml file', () async {
      await d.dir('foo', [
        analysisOptionsFile(experimentFlags: ['variance']),
        d.file('main.dart', 'class Writer<in T> {}'),
      ]).create();

      // Passing in a flag means the "variance" flag from the options file is
      // ignored and the variance syntax generates a parse error.
      var process = await runFormatterOnDir([
        '--enable-experiment=triple-shift',
      ]);

      expect(
        await process.stderr.next,
        'Could not format because the source could not be parsed:',
      );
      expect(await process.stderr.next, '');
      expect(
        await process.stderr.next,
        contains(
          'This requires the experimental \'variance\' language feature '
          'to be enabled.',
        ),
      );
      await process.shouldExit(65);
    });
  });
}

// The formatter doesn't actually support formatting variance annotations,
// but we want to test that the experiment flags are passed all the way
// to the parser, so just test that it parses the variance annotation
// without errors and then fails to format.
Future<void> _expectParseButNotFormat(TestProcess process) async {
  expect(
    process.stderr,
    emitsInOrder([
      startsWith('Hit a bug in the formatter when formatting'),
      'The formatter produced unexpected output. Input was:',
      'class Writer<in T> {}',
      '',
      'Which formatted to:',
      'class Writer<T> {}',
      '',
      'Please report at github.com/dart-lang/dart_style/issues.',
    ]),
  );
  await process.shouldExit(70);
}
