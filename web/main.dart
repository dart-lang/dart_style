import 'dart:html';

import 'package:dart_style/dart_style.dart';

TextAreaElement before;
TextAreaElement after;

void main() {
  before = querySelector("#before") as TextAreaElement;
  after = querySelector("#after") as TextAreaElement;

  before.onKeyUp.listen((event) {
    reformat();
  });

  reformat();
}

void reformat() {
  var source = before.value;

  try {
    var formatter = new CodeFormatter();
    after.value = formatter.format(CodeKind.STATEMENT, source).source;
    return;
  } on FormatterException catch(err) {
    // Do nothing.
  }

  // Maybe it's a statement.
  try {
    var formatter = new CodeFormatter();
    after.value = formatter.format(CodeKind.COMPILATION_UNIT, source).source;
  } on FormatterException catch(err) {
    // Maybe it's a statement.
    after.value = "Format failed:\n$err";
  }
}
