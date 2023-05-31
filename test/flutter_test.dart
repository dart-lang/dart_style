// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Temporary test file while working on Flutter style formatting.
@TestOn('vm')
library dart_style.test.flutter_test;

import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testDirectory('flutter');
}
