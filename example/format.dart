import 'package:dart_style/dart_style.dart';

import 'package:dart_style/src/debug.dart';

void main(List<String> args) {
  debugFormatter = true;
  useAnsiColors = true;

  formatStmt('{\n'
    '  a();\n'
    '\n'
    '  b();\n'
    '  c();\n'
    '}\n');
}

void formatStmt(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).formatStatement(source);

  result = highlightSpaces(result);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void formatUnit(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).format(source);

  result = highlightSpaces(result);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void drawRuler(String label, int width) {
  var padding = " " * (width - label.length - 1);
  print("$label:$padding|");
}

String highlightSpaces(String text) =>
    text.replaceAll(" ", "\u001b[1;30m·\u001b[0m");
