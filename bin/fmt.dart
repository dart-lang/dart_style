import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

main(List<String> args) {
  // This script is just for testing right now.

  //      1234567890123456789012345678901234567890
  // format("variable = longFunctionIsLoooooong(argument);\n");
  //format("var result = myFunction(argument * argument, argument * argument);");
  //format("var variableName =functionName(first, second);");
  //format("[first, [second, third, fourth], fifth, [sixth, seventh, eighth, nine, tenth, eleventh]];");
  //format("longFunctionIsLoooooooooooooong(argument, argument);");

  //format("[first,() {function.body;},third,fourth];");
  //format("method(first,second,third,fourth,fifth,() {fn;},third,fourth, fifth, sixth, seventh, eighth);");
  //format("longFunctionIsLoooooooooooooong(argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument, argument);");

  format("printNumbers(000000000000000000000, 111);");

  //reformatPub();
}

void format(String source) {
  var formatter = new CodeFormatter(new FormatterOptions(pageWidth: 40));
  var result = formatter.format(CodeKind.STATEMENT, source);

  print("before:                                 |");
  print(source);
  print("after:                                  |");
  print(result.source);
}

void reformatPub() {
  var dir = new Directory("/Users/rnystrom/dev/dart/dart/sdk/lib/_internal/pub");

  for (var entry in dir.listSync(recursive: true)) {
    if (!entry.path.endsWith(".dart")) continue;

    var relative = p.relative(entry.path, from: dir.path);
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