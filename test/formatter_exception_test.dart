// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

void main() async {
  test('message() does not throw', () {
    // This is a regression test for #358 where an error whose position is
    // past the end of the source caused FormatterException to throw.
    var formatter = DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    );

    expect(
      () => formatter.format('library'),
      throwsA(
        isA<FormatterException>().having(
          (e) => e.message(),
          'message',
          contains('Could not format'),
        ),
      ),
    );
  });

  test('describes parse errors', () {
    var formatter = DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    );

    expect(
      () {
        formatter.format('''

      var a = some error;

      var b = another one;
      ''', uri: 'my_file.dart');

        fail('Should throw.');
      },
      throwsA(
        isA<FormatterException>().having(
          (e) => e.message(),
          'message',
          allOf(
            contains('Could not format'),
            contains('line 2'),
            contains('line 4'),
          ),
        ),
      ),
    );
  });
}
