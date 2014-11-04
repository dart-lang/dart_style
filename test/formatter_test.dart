// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.formatter_test;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';

import 'package:dart_style/dart_style.dart';

void main() {
  // Tidy up the unittest output.
  filterStacks = true;
  formatStacks = true;
  useCompactVMConfiguration();

  testDirectory("whitespace");
  testDirectory("splitting");

  test("throws a FormatterException on failed parse", () {
    var formatter = new DartFormatter();
    expect(() => formatter.format('wat?!'),
       throwsA(new isInstanceOf<FormatterException>()));
  });

  test("adds newline to unit", () {
    expect(new DartFormatter().format("var x = 1;"),
        equals("var x = 1;\n"));
  });

  test("adds newline to unit after trailing comment", () {
    expect(new DartFormatter().format("library foo; //zamm"),
        equals("library foo; //zamm\n"));
  });

  test("removes extra newlines", () {
    expect(new DartFormatter().format("var x = 1;\n\n\n"),
        equals("var x = 1;\n"));
  });

  test("does not add newline to statement", () {
    expect(new DartFormatter().formatStatement("var x = 1;"),
        equals("var x = 1;"));
  });

  test('preserves initial indent', () {
    var formatter = new DartFormatter(indent: 2);
    expect(formatter.formatStatement('if (foo) {bar;}'),  equals(
        '    if (foo) {\n'
        '      bar;\n'
        '    }'));
  });
}

/// Run tests defined in "*.unit" and "*.stmt" files inside directory [name].
void testDirectory(String name) {
  var dir = p.join(p.dirname(p.fromUri(Platform.script)), name);
  for (var entry in new Directory(dir).listSync()) {
    if (!entry.path.endsWith(".stmt") && !entry.path.endsWith(".unit")) {
      continue;
    }

    group("$name ${p.basename(entry.path)}", () {
      var lines = (entry as File).readAsLinesSync();

      // The first line has a "|" to indicate the page width.
      var pageWidth = lines[0].indexOf("|");
      lines = lines.skip(1).toList();

      var i = 0;
      while (i < lines.length) {
        var description = lines[i++].replaceAll(">>>", "").trim();
        if (description == "") {
          description = "line ${i + 1}";
        } else {
          description = "line ${i + 1}: $description";
        }

        var input = "";
        while (!lines[i].startsWith("<<<")) {
          input += lines[i++] + "\n";
        }

        var expectedOutput = "";
        while (++i < lines.length && !lines[i].startsWith(">>>")) {
          expectedOutput += lines[i] + "\n";
        }

        // TODO(rnystrom): Temporary until I have all the tests passing.
        if (description.contains("SKIP")) {
          print("SKIPPING $name ${p.basename(entry.path)} $description");
          continue;
        }

        test(description, () {
          var formatter = new DartFormatter(pageWidth: pageWidth);

          var result;
          if (p.extension(entry.path) == ".stmt") {
            result = formatter.formatStatement(input) + "\n";
          } else {
            result = formatter.format(input);
          }

          expect(result, equals(expectedOutput));
        });
      }
    });
  }
}

// TODO(rnystrom): These tests are from when the formatter would make
// non-whitespace changes. Eventually, when style linting is supported, these
// should become linting errors.
/*
>>> DO use ; instead of {} for empty constructor bodies
class Point {
  int x, y;
  Point(this.x, this.y) {}
}
<<<
class Point {
  int x, y;
  Point(this.x, this.y);
}
>>> DO use curly braces for all flow control structures.
flow() {
  if (true) print('sanity');
  else
    print('opposite day!');
}
<<<
flow() {
  if (true) {
    print('sanity');
  } else {
    print('opposite day!');
  }
}

    test('CU (empty ctor bodies)', () {
      expectCUFormatsTo(
          'class A {\n'
          '  A() {\n'
          '  }\n'
          '}\n',
          'class A {\n'
          '  A();\n'
          '}\n'
      );
      expectCUFormatsTo(
          'class A {\n'
          '  A() {\n'
          '  }\n'
          '}\n',
          'class A {\n'
          '  A();\n'
          '}\n'
      );
    });

*/
