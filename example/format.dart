import 'package:dart_style/dart_style.dart';

void main(List<String> args) {
  formatStmt("sendPort.send({'type': 'error', 'error': 'oops'});");
  formatUnit("class Foo{}");
}

void formatStmt(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).formatStatement(source);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void formatUnit(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).format(source);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void drawRuler(String label, int width) {
  var padding = " " * (width - label.length - 1);
  print("$label:$padding|");
}