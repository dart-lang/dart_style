// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testDirectory('tall/declaration');
  await testDirectory('tall/expression');
  await testDirectory('tall/function');
  await testDirectory('tall/invocation');
  await testDirectory('tall/other');
  await testDirectory('tall/pattern');
  await testDirectory('tall/statement');
  await testDirectory('tall/top_level');
  await testDirectory('tall/type');
  await testDirectory('tall/variable');
  await testDirectory('tall/regression');

  await testBenchmarks(useTallStyle: true);
}
