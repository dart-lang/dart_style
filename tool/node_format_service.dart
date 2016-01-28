// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:js/js.dart';

import 'package:dart_style/dart_style.dart';

@JS()
@anonymous
class FormatResult {
  external factory FormatResult({String code, String error});
  external String get code;
  external String get error;
}

@JS('exports.formatCode')
external set formatCode(Function formatter);

void main() {
  formatCode = allowInterop((String source) {
    var formatter = new DartFormatter();
    try {
      return new FormatResult(
          code: new DartFormatter().format(source));
    } on FormatterException {
      // Do nothing.
    }

    // Maybe it's a statement.
    try {
      return new FormatResult(
          code: formatter.formatStatement(source));
    } on FormatterException catch (err) {
      return new FormatResult(code: source, error: "$err");
    }
  });
}
