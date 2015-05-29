import 'dart:html';

import 'package:dart_style/dart_style.dart';

TextAreaElement before;
TextAreaElement after;

int width = 80;

void main() {
  before = querySelector("#before") as TextAreaElement;
  after = querySelector("#after") as TextAreaElement;

  before.onKeyUp.listen((event) {
    reformat();
  });

  var columnMarker = querySelector(".column-marker");

  var widthInput = querySelector("#width") as InputElement;
  var widthOutput = querySelector("#width-output") as OutputElement;

  widthInput.onInput.listen((event) {
    widthOutput.value = widthInput.value;
    width = int.parse(widthInput.value);
    var pad = " " * width + "|";
    columnMarker.innerHtml = "$pad $width columns" + "\n$pad" * 29;
    reformat();
  });

  reformat();
}

void reformat() {
  var source = before.value;

  try {
    after.value = new DartFormatter(pageWidth: width).format(source);
    return;
  } on FormatterException {
    // Do nothing.
  }

  // Maybe it's a statement.
  try {
    after.value = new DartFormatter(pageWidth: width).formatStatement(source);
  } on FormatterException catch (err) {
    after.value = "Format failed:\n$err";
  }
}
