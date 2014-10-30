import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

main(List<String> args) {
  if (args.length == 1) {
    if (new Directory(args[0]).existsSync()) {
      reformatDirectory(args[0]);
    } else if (new File(args[0]).existsSync()) {
      reformatFile(args[0]);
    } else {
      // TODO(rnystrom): Report error.
    }

    return;
  }

  // This code is just for testing right now.

  /*
1234567890123456789012345678901234567890
            */
  formatUnit("foo() {\n//comment\n}");
}

void formatStmt(String source, [int pageWidth = 40]) {
  var formatter = new CodeFormatter(new FormatterOptions(pageWidth: pageWidth));
  var result = formatter.format(CodeKind.STATEMENT, source);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void formatUnit(String source, [int pageWidth = 40]) {
  var formatter = new CodeFormatter(new FormatterOptions(pageWidth: pageWidth));
  var result = formatter.format(CodeKind.COMPILATION_UNIT, source);

  drawRuler("before", pageWidth);
  print(source);
  drawRuler("after", pageWidth);
  print(result);
}

void drawRuler(String label, int width) {
  var padding = " " * (width - label.length + 2);
  print("$label:$padding|");
}

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
void reformatDirectory(String path) {
  for (var entry in new Directory(path).listSync(recursive: true)) {
    if (!entry.path.endsWith(".dart")) continue;

    var relative = p.relative(entry.path, from: path);
    print(relative);

    var formatter = new CodeFormatter();
    try {
      var file = entry as File;
      var source = file.readAsStringSync();
      var formatted = formatter.format(CodeKind.COMPILATION_UNIT, source);
      file.writeAsStringSync(formatted);
      print("$relative: done");
    } on FormatterException catch(err) {
      print("$relative: failed with\n$err");
    }
  }
}

void reformatFile(String path) {
  var formatter = new CodeFormatter();
  try {
    var file = new File(path);
    var source = file.readAsStringSync();
    var formatted = formatter.format(CodeKind.COMPILATION_UNIT, source);
    file.writeAsStringSync(formatted);
    print("$path: done");
  } on FormatterException catch(err) {
    print("$path: failed with\n$err");
  }
}
