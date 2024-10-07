// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../utils.dart';

void main() {
  compileFormatter();

  group('stdin', () {
    test('errors on --output=write', () async {
      var process = await runFormatter(['--output=write']);
      await process.shouldExit(64);
    });

    test('exits with 65 on parse error', () async {
      var process = await runFormatter();
      process.stdin.writeln('herp derp i are a dart');
      await process.stdin.close();
      await process.shouldExit(65);
    });

    test('reads from stdin', () async {
      var process = await runFormatter();
      process.stdin.writeln(unformattedSource);
      await process.stdin.close();

      // No trailing newline at the end.
      expect(await process.stdout.next, formattedOutput);
      await process.shouldExit(0);
    });
  });

  group('--stdin-name', () {
    test('errors if also given path', () async {
      var process = await runFormatter(['--stdin-name=name', 'path']);
      await process.shouldExit(64);
    });

    test('used in error messages', () async {
      var path = p.join('some', 'path.dart');
      var process = await runFormatter(['--stdin-name=$path']);
      process.stdin.writeln('herp');
      await process.stdin.close();

      expect(await process.stderr.next,
          'Could not format because the source could not be parsed:');
      expect(await process.stderr.next, '');
      expect(await process.stderr.next, contains(path));
      await process.stderr.cancel();
      await process.shouldExit(65);
    });
  });
}
