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

    test('uses latest language version if no surrounding package', () async {
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
    test('no package search if language version is specified', () async {
      // Put the file in a directory with a malformed package config. If we
      // search for it, we should get an error.
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main(){    }'),
      ]).create();

      var process = await runFormatterOnDir(['--language-version=latest']);
      await process.shouldExit(0);

      // Should format the file without any error reading the package config.
      await d.dir('foo', [d.file('main.dart', 'main() {}\n')]).validate();
    });

    test('default to language version of surrounding package', () async {
      // The package config sets the language version to 2.19, but pattern
      // variables are only available in 3.0 and later. Verify that the error
      // is reported.
      await d.dir('foo', [
        packageConfig('foo', version: '2.19'),
        d.file('main.dart', 'main() { var (a, b) = (1, 2); }'),
      ]).create();

      var path = p.join(d.sandbox, 'foo', 'main.dart');
      var process = await runFormatter([path]);

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

    test('use the latest version if the package config is malformed', () async {
      await d.dir('foo', [
        d.dir('.dart_tool', [
          d.file('package_config.json', 'this no good json is bad json'),
        ]),
        d.file('main.dart', 'main() {var (a,b)=(1,2);}'),
      ]).create();

      var process = await runFormatterOnDir();
      await process.shouldExit(0);

      // Formats the file.
      await d.dir('foo', [
        d.file('main.dart', '''
main() {
  var (a, b) = (1, 2);
}
''')
      ]).validate();
    });
  });

  group('stdin', () {
    test('infers language version from surrounding package', () async {
      // The package config sets the language version to 2.19, when switch
      // cases still allowed arbitrary constant expressions like `1 + 2`.
      // Verify that the code is formatted without error.
      await d.dir('foo', [
        packageConfig('foo', version: '2.19'),
      ]).create();

      var process = await runFormatter(['--stdin-name=foo/main.dart']);
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
        '--stdin-name=foo/main.dart',
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

    test('use latest language version if no surrounding package', () async {
      await d.dir('foo', []).create();

      var process = await runFormatter(['--stdin-name=foo/main.dart']);
      // Use some relatively recent syntax.
      process.stdin.writeln('main() {var (a,b)=(1,2);}');
      await process.stdin.close();

      expect(await process.stdout.next, 'main() {');
      expect(await process.stdout.next, '  var (a, b) = (1, 2);');
      expect(await process.stdout.next, '}');
      await process.shouldExit(0);
    });
  });

  group('style', () {
    test('uses the short style on 3.6 or earlier', () async {
      const before = 'main() { f(argument, // comment\nanother);}';
      const after = '''
main() {
  f(
      argument, // comment
      another);
}
''';

      await d.dir('code', [d.file('a.dart', before)]).create();

      var process = await runFormatterOnDir(['--language-version=3.6']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', after)]).validate();
    });

    test('uses the tall style on 3.7 or earlier', () async {
      const before = 'main() { f(argument, // comment\nanother);}';
      const after = '''
main() {
  f(
    argument, // comment
    another,
  );
}
''';

      await d.dir('code', [d.file('a.dart', before)]).create();

      var process = await runFormatterOnDir(['--language-version=3.7']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', after)]).validate();
    });

    test('language version comment override opts into short style', () async {
      const before = '''
// @dart=3.6
main() { f(argument, // comment
another);}
''';
      const after = '''
// @dart=3.6
main() {
  f(
      argument, // comment
      another);
}
''';

      await d.dir('code', [d.file('a.dart', before)]).create();

      var process = await runFormatterOnDir(['--language-version=3.7']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', after)]).validate();
    });

    test('language version comment override opts into tall style', () async {
      // Note that in real-world code it doesn't make sense for a language
      // version comment to be *higher* than the specified default language
      // version before you can't use a comment that's higher than the minimum
      // version in the package's SDK constraint. (Otherwise, you could end up
      // trying to run a library whose language version isn't supported by the
      // SDK you are running it in.)
      //
      // But we support it in the formatter since it's possible to specify a
      // default language version using mechanisms other than the pubspec SDK
      // constraint.
      const before = '''
// @dart=3.7
main() { f(argument, // comment
another);}
''';
      const after = '''
// @dart=3.7
main() {
  f(
    argument, // comment
    another,
  );
}
''';

      await d.dir('code', [d.file('a.dart', before)]).create();

      var process = await runFormatterOnDir(['--language-version=3.6']);
      await process.shouldExit(0);

      await d.dir('code', [d.file('a.dart', after)]).validate();
    });
  });
}
