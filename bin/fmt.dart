import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/line_printer.dart';

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

  //          1234567890123456789012345678901234567890
  //formatStmt("var variableName = thisIsReallyQuiteAVeryLongVariableName;");
}

void formatStmt(String source) {
  LinePrinter.debug = true;

  var formatter = new CodeFormatter(new FormatterOptions(pageWidth: 40));
  var result = formatter.format(CodeKind.STATEMENT, source);

  print("before:                                 |");
  print(source);
  print("after:                                  |");
  print(result.source);
}

void formatUnit(String source) {
  LinePrinter.debug = true;

  var formatter = new CodeFormatter(new FormatterOptions(pageWidth: 40));
  var result = formatter.format(CodeKind.COMPILATION_UNIT, source);

  print("before:                                 |");
  print(source);
  print("after:                                  |");
  print(result.source);
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
      var formatted = formatter.format(CodeKind.COMPILATION_UNIT, source).source;
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
    var formatted = formatter.format(CodeKind.COMPILATION_UNIT, source).source;
    file.writeAsStringSync(formatted);
    print("$path: done");
  } on FormatterException catch(err) {
    print("$path: failed with\n$err");
  }
}
