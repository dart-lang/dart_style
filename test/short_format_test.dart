// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testDirectory('short/comments');
  await testDirectory('short/regression');
  await testDirectory('short/selections');
  await testDirectory('short/splitting');
  await testDirectory('short/whitespace');

  await testBenchmarks(useTallStyle: false);
}
