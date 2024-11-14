// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() async {
  group('short style', () {
    _runTests(isTall: false);
  });

  group('tall style', () {
    _runTests(isTall: true);
  });
}

/// Run all of the DartFormatter tests either using short or tall style.
void _runTests({required bool isTall}) {
  DartFormatter makeFormatter(
      {Version? languageVersion, int? indent, String? lineEnding}) {
    languageVersion ??= isTall
        ? DartFormatter.latestLanguageVersion
        : DartFormatter.latestShortStyleLanguageVersion;

    return DartFormatter(
        languageVersion: languageVersion,
        indent: indent,
        lineEnding: lineEnding);
  }

  group('language version', () {
    test('defaults to latest if omitted', () {
      var formatter = makeFormatter();
      expect(
          formatter.languageVersion,
          isTall
              ? DartFormatter.latestLanguageVersion
              : DartFormatter.latestShortStyleLanguageVersion);
    });

    test('parses at given older language version', () {
      // Use a language version before patterns were supported and a pattern
      // is an error.
      var formatter = makeFormatter(languageVersion: Version(2, 19, 0));
      expect(() => formatter.format('main() {switch (o) {case var x: break;}}'),
          throwsA(isA<FormatterException>()));
    });

    test('parses at given newer language version', () {
      // Use a language version after patterns were supported and `1 + 2` is an
      // error.
      var formatter = makeFormatter(languageVersion: Version(3, 0, 0));
      expect(() => formatter.format('main() {switch (o) {case 1+2: break;}}'),
          throwsA(isA<FormatterException>()));
    });

    test('@dart comment overrides version', () {
      // Use a language version after patterns were supported and `1 + 2` is an
      // error.
      var formatter = makeFormatter(languageVersion: Version(3, 0, 0));

      // But then have the code opt to the older version.
      const before = '''
// @dart=2.19
main() { switch (o) { case 1+2: break; } }
''';

      const after = '''
// @dart=2.19
main() {
  switch (o) {
    case 1 + 2:
      break;
  }
}
''';

      expect(formatter.format(before), after);
    });
  });

  test('language version comment override opts into short style', () async {
    // Use a language version with tall style.
    var formatter = makeFormatter(languageVersion: Version(3, 7, 0));

    // But the code has a comment to opt into the short style.
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

    expect(formatter.format(before), after);
  });

  test('language version comment override opts into tall style', () async {
    // Use a language version with short style.
    var formatter = makeFormatter(languageVersion: Version(3, 6, 0));

    // But the code has a comment to opt into the tall style.
    //
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

    expect(formatter.format(before), after);
  });

  test('throws a FormatterException on failed parse', () {
    var formatter = makeFormatter();
    expect(() => formatter.format('wat?!'), throwsA(isA<FormatterException>()));
  });

  test('FormatterException.message() does not throw', () {
    // This is a regression test for #358 where an error whose position is
    // past the end of the source caused FormatterException to throw.
    expect(
        () => makeFormatter().format('library'),
        throwsA(isA<FormatterException>().having(
            (e) => e.message(), 'message', contains('Could not format'))));
  });

  test('FormatterException describes parse errors', () {
    expect(() {
      makeFormatter().format('''

      var a = some error;

      var b = another one;
      ''', uri: 'my_file.dart');

      fail('Should throw.');
    },
        throwsA(isA<FormatterException>().having(
            (e) => e.message(),
            'message',
            allOf(contains('Could not format'), contains('line 2'),
                contains('line 4')))));
  });

  test('adds newline to unit', () {
    expect(makeFormatter().format('var x = 1;'), equals('var x = 1;\n'));
  });

  test('adds newline to unit after trailing comment', () {
    expect(makeFormatter().format('library foo; //zamm'),
        equals('library foo; //zamm\n'));
  });

  test('removes extra newlines', () {
    expect(makeFormatter().format('var x = 1;\n\n\n'), equals('var x = 1;\n'));
  });

  test('does not add newline to statement', () {
    expect(makeFormatter().formatStatement('var x = 1;'), equals('var x = 1;'));
  });

  test('fails if anything is after the statement', () {
    expect(
        () => makeFormatter().formatStatement('var x = 1;;'),
        throwsA(isA<FormatterException>()
            .having((e) => e.errors.length, 'errors.length', equals(1))
            .having((e) => e.errors.first.offset, 'errors.length.first.offset',
                equals(10))));
  });

  test('preserves initial indent', () {
    var formatter = makeFormatter(indent: 3);
    expect(
        formatter.formatStatement('if (foo) {bar;}'),
        equals('   if (foo) {\n'
            '     bar;\n'
            '   }'));
  });

  group('line endings', () {
    test('uses given line ending', () {
      // Use zero width no-break space character as the line ending. We have
      // to use a whitespace character for the line ending as the formatter
      // will throw an error if it accidentally makes non-whitespace changes
      // as would occur if we used a non-whitespace character as the line
      // ending.
      var lineEnding = '\t';
      expect(makeFormatter(lineEnding: lineEnding).format('var i = 1;'),
          equals('var i = 1;\t'));
    });

    test('infers \\r\\n if the first newline uses that', () {
      expect(makeFormatter().format('var\r\ni\n=\n1;\n'),
          equals('var i = 1;\r\n'));
    });

    test('infers \\n if the first newline uses that', () {
      expect(makeFormatter().format('var\ni\r\n=\r\n1;\r\n'),
          equals('var i = 1;\n'));
    });

    test('defaults to \\n if there are no newlines', () {
      expect(makeFormatter().format('var i =1;'), equals('var i = 1;\n'));
    });

    test('handles Windows line endings in multiline strings', () {
      expect(
          makeFormatter(lineEnding: '\r\n').formatStatement('  """first\r\n'
              'second\r\n'
              'third"""  ;'),
          equals('"""first\r\n'
              'second\r\n'
              'third""";'));
    });
  });

  test('throws an UnexpectedOutputException on non-whitespace changes', () {
    // Use an invalid line ending character to ensure the formatter will
    // attempt to make non-whitespace changes.
    var formatter = makeFormatter(lineEnding: '%');
    expect(() => formatter.format('var i = 1;'),
        throwsA(isA<UnexpectedOutputException>()));
  });
}
