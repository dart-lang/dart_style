// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import '../utils.dart';

void main() {
  compileFormatter();

  group('--language-version', () {
    // It's hard to validate that the formatter uses the *exact* latest
    // language version supported by the formatter, but at least test that a
    // new-ish language feature can be parsed.
    const extensionTypeBefore = '''
extension type Meters(int value) {
  Meters operator+(Meters other) => Meters(value+other.value);
}''';

    const extensionTypeAfter = '''
extension type Meters(int value) {
  Meters operator +(Meters other) => Meters(value + other.value);
}
''';

    test('defaults to latest language version if omitted', () async {
      await d.dir('code', [d.file('a.dart', extensionTypeBefore)]).create();

      var process = await runFormatterOnDir();
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', extensionTypeAfter)]).validate();
    });

    test('uses the given language version', () async {
      const before = 'main() { switch (o) { case 1+2: break; } }';

      const after = '''
main() {
  switch (o) {
    case 1 + 2:
      break;
  }
}
''';

      await d.dir('code', [d.file('a.dart', before)]).create();

      // Use an older language version where `1 + 2` was still a valid switch
      // case.
      var process = await runFormatterOnDir(['--language-version=2.19']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', after)]).validate();
    });

    test('uses the latest language version if "latest"', () async {
      await d.dir('code', [d.file('a.dart', extensionTypeBefore)]).create();

      var process = await runFormatterOnDir(['--language-version=latest']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', extensionTypeAfter)]).validate();
    });

    test("errors if the language version can't be parsed", () async {
      var process = await runFormatter(['--language-version=123']);
      await process.shouldExit(64);
    });
  });

  group('package config', () {
    // TODO(rnystrom): Remove this test when the experiment ships.
    test('no package search if experiment is off', () async {
      // Put the file in a directory with a malformed package config. If we
      // search for it, we should get an error.
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main(){    }'),
      ]).create();

      var process = await runFormatterOnDir();
      await process.shouldExit(0);

      // Should format the file without any error reading the package config.
      await d.dir('foo', [d.file('main.dart', 'main() {}\n')]).validate();
    });

    test('no package search if language version is specified', () async {
      // Put the file in a directory with a malformed package config. If we
      // search for it, we should get an error.
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main(){    }'),
      ]).create();

      var process = await runFormatterOnDir(
          ['--language-version=latest', '--enable-experiment=tall-style']);
      await process.shouldExit(0);

      // Should format the file without any error reading the package config.
      await d.dir('foo', [d.file('main.dart', 'main() {}\n')]).validate();
    });

    test('default to language version of surrounding package', () async {
      // The package config sets the language version to 3.1, but the switch
      // case uses a syntax which is valid in earlier versions of Dart but an
      // error in 3.0 and later. Verify that the error is reported.
      await d.dir('foo', [
        packageConfig('foo', version: '3.1'),
        d.file('main.dart', 'main() { switch (o) { case 1 + 2: break; } }'),
      ]).create();

      var path = p.join(d.sandbox, 'foo', 'main.dart');
      // TODO(rnystrom): Remove experiment flag when it ships.
      var process =
          await runFormatter([path, '--enable-experiment=tall-style']);

      expect(await process.stderr.next,
          'Could not format because the source could not be parsed:');
      expect(await process.stderr.next, '');
      expect(await process.stderr.next, contains('main.dart'));
      await process.shouldExit(65);
    });

    test('language version comment overrides package default', () async {
      // The package config sets the language version to 3.1, but the switch
      // case uses a syntax which is valid in earlier versions of Dart but an
      // error in 3.0 and later. Verify that no error is reported since this
      // file opts to the older version.
      await d.dir('foo', [
        packageConfig('foo', version: '3.1'),
        d.file('main.dart', '''
          // @dart=2.19
          main() { switch (obj) { case 1 + 2: // Error in 3.1.
            } }
          '''),
      ]).create();

      var process = await runFormatterOnDir();
      await process.shouldExit(0);

      // Formats the file.
      await d.dir('foo', [
        d.file('main.dart', '''
// @dart=2.19
main() {
  switch (obj) {
    case 1 + 2: // Error in 3.1.
  }
}
''')
      ]).validate();
    });

    test('malformed', () async {
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main() {}'),
      ]).create();

      var path = p.join(d.sandbox, 'foo', 'main.dart');
      // TODO(rnystrom): Remove experiment flag when it ships.
      var process =
          await runFormatter([path, '--enable-experiment=tall-style']);

      expect(
          await process.stderr.next,
          allOf(startsWith('Could not read package configuration for'),
              contains(p.join('foo', 'main.dart'))));
      await process.shouldExit(65);
    });
  });

  group('stdin', () {
    test('infers language version from surrounding package', () async {
      // The package config sets the language version to 3.1, but the switch
      // case uses a syntax which is valid in earlier versions of Dart but an
      // error in 3.0 and later. Verify that the error is reported.
      await d.dir('foo', [
        packageConfig('foo', version: '2.19'),
      ]).create();

      var process = await runFormatter(
          ['--enable-experiment=tall-style', '--stdin-name=foo/main.dart']);
      // Write a switch whose syntax is valid in 2.19, but an error in later
      // versions.
      process.stdin.writeln('main() { switch (o) { case 1 + 2: break; } }');
      await process.stdin.close();

      expect(await process.stdout.next, 'main() {');
      expect(await process.stdout.next, '  switch (o) {');
      expect(await process.stdout.next, '    case 1 + 2:');
      expect(await process.stdout.next, '      break;');
      expect(await process.stdout.next, '  }');
      expect(await process.stdout.next, '}');
      await process.shouldExit(0);
    });

    test('no package search if language version is specified', () async {
      // Put the stdin-name in a directory with a malformed package config. If
      // we search for it, we should get an error.
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main(){    }'),
      ]).create();

      var process = await runFormatter([
        '--language-version=2.19',
        '--enable-experiment=tall-style',
        '--stdin-name=foo/main.dart'
      ]);

      // Write a switch whose syntax is valid in 2.19, but an error in later
      // versions.
      process.stdin.writeln('main() { switch (o) { case 1 + 2: break; } }');
      await process.stdin.close();

      expect(await process.stdout.next, 'main() {');
      expect(await process.stdout.next, '  switch (o) {');
      expect(await process.stdout.next, '    case 1 + 2:');
      expect(await process.stdout.next, '      break;');
      expect(await process.stdout.next, '  }');
      expect(await process.stdout.next, '}');
      await process.shouldExit(0);
    });
  });
}
