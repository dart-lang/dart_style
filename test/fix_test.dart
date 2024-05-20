// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() async {
  await testFile('short/fixes/named_default_separator.unit',
      fixes: [StyleFix.namedDefaultSeparator]);
  await testFile('short/fixes/doc_comments.stmt',
      fixes: [StyleFix.docComments]);
  await testFile('short/fixes/function_typedefs.unit',
      fixes: [StyleFix.functionTypedefs]);
  await testFile('short/fixes/optional_const.unit',
      fixes: [StyleFix.optionalConst]);
  await testFile('short/fixes/optional_new.stmt',
      fixes: [StyleFix.optionalNew]);
  await testFile('short/fixes/single_cascade_statements.stmt',
      fixes: [StyleFix.singleCascadeStatements]);
}
