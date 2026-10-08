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

  group('language version', () {
    test('parses at given older language version', () {
      // Use a language version before patterns were supported and a pattern
      // is an error.
      var formatter = DartFormatter(languageVersion: Version(2, 19, 0));

      expectFormatBothThrows<FormatterException>(
        formatter,
        'main() {switch (o) {case var x: break;}}',
      );
    });

    test('parses at given newer language version', () {
      // Use a language version after patterns were supported and `1 + 2` is an
      // error.
      var formatter = DartFormatter(languageVersion: Version(3, 0, 0));
      expectFormatBothThrows<FormatterException>(
        formatter,
        'main() {switch (o) {case 1+2: break;}}',
      );
    });

    test('@dart comment overrides version', () {
      // Use a language version after patterns were supported and `1 + 2` is an
      // error.
      var formatter = DartFormatter(languageVersion: Version(3, 0, 0));

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

      expectFormatUnit(formatter, before, after);
    });

    test('comment override opts into short style', () async {
      // Use a language version with tall style.
      var formatter = DartFormatter(languageVersion: Version(3, 7, 0));

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

      expectFormatUnit(formatter, before, after);
    });

    test('comment override opts into tall style', () async {
      // Use a language version with short style.
      var formatter = DartFormatter(languageVersion: Version(3, 6, 0));

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

      expectFormatUnit(formatter, before, after);
    });

    test('comment override changes language versioned style change', () async {
      // Use a language version at a later style.
      var formatter = DartFormatter(languageVersion: Version(3, 8, 0));

      // But the code has a comment to opt into an older but still tall style.
      // In 3.8, we allow the condition part of a `?:` on the same line as an
      // assignment. In 3.7, we don't.
      const before = '''
// @dart=3.7
var variable = condition
    ? thenBranch // Comment to force split.
    : elseBranch;
''';
      const after = '''
// @dart=3.7
var variable =
    condition
        ? thenBranch // Comment to force split.
        : elseBranch;
''';

      expectFormatUnit(formatter, before, after);
    });
  });
}

/// Run all of the DartFormatter tests either using short or tall style.
void _runTests({required bool isTall}) {
  DartFormatter makeFormatter({
    int? indent,
    String? lineEnding,
    List<String>? experimentFlags,
  }) {
    return DartFormatter(
      languageVersion: isTall
          ? DartFormatter.latestLanguageVersion
          : DartFormatter.latestShortStyleLanguageVersion,
      indent: indent,
      lineEnding: lineEnding,
      experimentFlags: experimentFlags,
    );
  }

  group('experiment flags', () {
    test('passes experiment flags to parser', () {
      var formatter = makeFormatter(experimentFlags: ['variance']);
      expectFormatUnitThrows<UnexpectedOutputException>(
        formatter,
        'class Writer<in T> {}',
      );
    });
  });

  test('throws a FormatterException on failed parse', () {
    var formatter = makeFormatter();
    expectFormatBothThrows<FormatterException>(formatter, 'wat?!');
  });

  test('adds newline to unit', () {
    var formatter = makeFormatter();
    expectFormatUnit(formatter, 'var x = 1;', 'var x = 1;\n');
  });

  test('adds newline to unit after trailing comment', () {
    var formatter = makeFormatter();
    expectFormatUnit(formatter, 'library foo; //zamm', 'library foo; //zamm\n');
  });

  test('removes extra newlines', () {
    var formatter = makeFormatter();
    expectFormatUnit(formatter, 'var x = 1;\n\n\n', 'var x = 1;\n');
  });

  test('does not add newline to statement', () {
    var formatter = makeFormatter();
    expectFormatStatement(formatter, 'var x = 1;', 'var x = 1;');
  });

  test('fails if anything is after the statement', () {
    expect(
      () => makeFormatter().formatStatement('var x = 1;;'),
      throwsA(
        isA<FormatterException>()
            .having((e) => e.errors.length, 'errors.length', equals(1))
            .having(
              (e) => e.errors.first.offset,
              'errors.length.first.offset',
              equals(10),
            ),
      ),
    );
  });

  test('preserves initial indent', () {
    var formatter = makeFormatter(indent: 3);
    expectFormatStatement(
      formatter,
      'if (foo) {bar;}',
      '   if (foo) {\n'
          '     bar;\n'
          '   }',
    );
  });

  group('line endings', () {
    test('uses given line ending', () {
      // Use zero width no-break space character as the line ending. We have
      // to use a whitespace character for the line ending as the formatter
      // will throw an error if it accidentally makes non-whitespace changes
      // as would occur if we used a non-whitespace character as the line
      // ending.
      var lineEnding = '\t';
      var formatter = makeFormatter(lineEnding: lineEnding);
      expectFormatUnit(formatter, 'var i = 1;', 'var i = 1;\t');
    });

    test('infers \\r\\n if the first newline uses that', () {
      var formatter = makeFormatter();
      expectFormatUnit(formatter, 'var\r\ni\n=\n1;\n', 'var i = 1;\r\n');
    });

    test('infers \\n if the first newline uses that', () {
      var formatter = makeFormatter();
      expectFormatUnit(formatter, 'var\ni\r\n=\r\n1;\r\n', 'var i = 1;\n');
    });

    test('defaults to \\n if there are no newlines', () {
      var formatter = makeFormatter();
      expectFormatUnit(formatter, 'var i =1;', 'var i = 1;\n');
    });

    test('handles Windows line endings in multiline strings', () {
      const code =
          'var x = """first\r\n'
          'second\r\n'
          'third""";';
      var formatter = makeFormatter(lineEnding: '\r\n');
      expectFormatUnit(formatter, code, '$code\r\n');
      expectFormatStatement(formatter, code, code);
    });

    test('DartFormat.lineEnding getter is not mutated by inferred ending', () {
      var formatter = makeFormatter();
      expect(formatter.lineEnding, isNull);

      formatter.format('var\r\ni\n=\n1;\n');
      expect(formatter.lineEnding, isNull);

      formatter.format('var\ni\n=\n1;\n');
      expect(formatter.lineEnding, isNull);
    });

    test('DartFormat.lineEnding setter does nothing', () {
      var formatter = makeFormatter(lineEnding: 'before');
      expect(formatter.lineEnding, 'before');

      formatter.lineEnding = 'after';
      expect(formatter.lineEnding, 'before');
    });
  });

  test('throws an UnexpectedOutputException on non-whitespace changes', () {
    // Use an invalid line ending character to ensure the formatter will
    // attempt to make non-whitespace changes.
    var formatter = makeFormatter(lineEnding: '%');
    expectFormatBothThrows<UnexpectedOutputException>(
      formatter,
      'var x = // c\n1;',
    );
  });
}

/// Validates that formatting [source] using [formatter] produces [expected].
///
/// The [source] should be a valid compilation unit but is not a valid
/// statement. Tests that [format()] and [formatSource()] both pass the
/// expectation.
void expectFormatUnit(DartFormatter formatter, String source, String expected) {
  expect(formatter.format(source), expected);
  expect(formatter.formatSource(SourceCode(source)).text, expected);
}

/// Validates that formatting [source] using [formatter] produces [expected].
///
/// The [source] should be a valid statement but is not a valid compilation
/// unit. Tests that [formatStatement()] and [formatSource()] both pass the
/// expectation.
void expectFormatStatement(
  DartFormatter formatter,
  String source,
  String expected,
) {
  expect(formatter.formatStatement(source), expected);
  expect(
    formatter.formatSource(SourceCode(source, isCompilationUnit: false)).text,
    expected,
  );
}

/// Validates that formatting [source] using [formatter] throws an error of
/// type [E].
///
/// The [source] should be both a valid compilation unit and a valid statement.
/// Tests that [format()], [formatSource()], and [formatStatement()] all throw
/// the error.
void expectFormatBothThrows<E>(DartFormatter formatter, String source) {
  expectFormatUnitThrows<E>(formatter, source);

  expect(() => formatter.formatStatement(source), throwsA(isA<E>()));
  expect(
    () => formatter
        .formatSource(SourceCode(source, isCompilationUnit: false))
        .text,
    throwsA(isA<E>()),
  );
}

/// Validates that formatting [source] using [formatter] throws an error of
/// type [E].
///
/// The [source] should be a valid compilation unit. Tests that [format()] and
/// [formatSource()] both throw the error.
void expectFormatUnitThrows<E>(DartFormatter formatter, String source) {
  expect(() => formatter.format(source), throwsA(isA<E>()));
  expect(
    () => formatter.formatSource(SourceCode(source)).text,
    throwsA(isA<E>()),
  );
}
