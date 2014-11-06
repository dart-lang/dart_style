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
    after.value = new DartFormatter().format(source);
    return;
  } on FormatterException catch(err) {
    // Do nothing.
  }

  // Maybe it's a statement.
  try {
    after.value = new DartFormatter().formatStatement(source);
  } on FormatterException catch(err) {
    after.value = "Format failed:\n$err";
  }
}
