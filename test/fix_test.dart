// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library dart_style.test.fix_test;

import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testFile('fixes/named_default_separator.unit',
      tall: false, fixes: [StyleFix.namedDefaultSeparator]);
  await testFile('fixes/doc_comments.stmt',
      tall: false, fixes: [StyleFix.docComments]);
  await testFile('fixes/function_typedefs.unit',
      tall: false, fixes: [StyleFix.functionTypedefs]);
  await testFile('fixes/optional_const.unit',
      tall: false, fixes: [StyleFix.optionalConst]);
  await testFile('fixes/optional_new.stmt',
      tall: false, fixes: [StyleFix.optionalNew]);
  await testFile('fixes/single_cascade_statements.stmt',
      tall: false, fixes: [StyleFix.singleCascadeStatements]);
}
