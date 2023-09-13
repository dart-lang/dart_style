// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library dart_style.test.tall_format_test;

import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testDirectory('expression', tall: true);
  await testDirectory('statement', tall: true);
  await testDirectory('top_level', tall: true);

  // TODO(tall): The old formatter_test.dart has tests here for things like
  // trailing newlines. Port those over to the new style once it supports all
  // the syntax those tests rely on.
}
