import 'package:dart_style/dart_style.dart';

import 'package:dart_style/src/debug.dart';

void main(List<String> args) {
  debugFormatter = true;
  useAnsiColors = true;

  formatStmt("""
a____________(b___________(c_____________(d_______________,() {body;}, e_______________________,f___________), g_____________,h_____________));
  """);
}

void formatStmt(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).formatStatement(source);

  //result = result.split("\n").map((line) => "|$line|").join("\n");

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void formatUnit(String source, [int pageWidth = 40]) {
  var result = new DartFormatter(pageWidth: pageWidth).format(source);

  //result = result.split("\n").map((line) => "|$line|").join("\n");

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void drawRuler(String label, int width) {
  var padding = " " * (width - label.length - 1);
  print("$label:$padding|");
}