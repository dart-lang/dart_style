// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
@TestOn('vm')
library dart_style.test.experiment_test;

import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testDirectory('experiment/comments', experimentalStyle: true);
  await testDirectory('experiment/flutter', experimentalStyle: true);
  await testDirectory('experiment/regression', experimentalStyle: true);
  await testDirectory('experiment/selections', experimentalStyle: true);
  await testDirectory('experiment/splitting', experimentalStyle: true);
  await testDirectory('experiment/whitespace', experimentalStyle: true);

  test('Uses experimental style if marker comment present', () {
    expect(
        DartFormatter(pageWidth: 20)
            .formatStatement('// DO NOT SUBMIT USE DART FORMAT EXPERIMENT\n'
                'function(argument, another);'),
        equals('// DO NOT SUBMIT USE DART FORMAT EXPERIMENT\n'
            'function(\n'
            '  argument,\n'
            '  another,\n'
            ');'));
  });
}
