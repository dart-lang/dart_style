// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.formatter_test;

import 'dart:io';

import 'package:analyzer/src/generated/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';

import 'package:dart_style/dart_style.dart';

import 'token_stream_comparator.dart';

// Test data location.
final testDataDir = p.join(p.dirname(p.fromUri(Platform.script)), 'data');

main() {
  // Tidy up the unittest output.
  filterStacks = true;
  formatStacks = true;
  useCompactVMConfiguration();

  testDirectory("splitting");

  // TODO(rnystrom): Eventually move all of these to using testDirectory().
  // Data-driven compilation unit tests.
  for (var entry in new Directory(testDataDir).listSync()) {
    if (entry.path.endsWith(".unit")) {
      runTests(p.basename(entry.path), (input, expectedOutput) {
        expectCUFormatsTo(input, expectedOutput);
      });
    }
  }

  // Data-driven statement tests.
  for (var entry in new Directory(testDataDir).listSync()) {
    if (entry.path.endsWith(".stmt")) {
      // NOTE: statement tests are run with transforms enabled.
      runTests(p.basename(entry.path), (input, expectedOutput) {
        expect(formatStatement(input) + '\n', equals(expectedOutput));
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

  /// Formatter tests
  group('formatter', () {
    test('failed parse', () {
      var formatter = new CodeFormatter();
      expect(() => formatter.format(CodeKind.COMPILATION_UNIT, '~'),
                   throwsA(new isInstanceOf<FormatterException>()));
    });

    test('indent', () {
      var original =
          'class A {\n'
          '  var z;\n'
          '  inc(int x) => ++x;\n'
          '  foo(int x) {\n'
          '    if (x == 0) {\n'
          '      return true;\n'
          '    }\n'
          '  }\n'
          '}\n';
      expectCUFormatsTo(
          original,
          original
        );
    });

    test('CU (1)', () {
      expectCUFormatsTo(
          'class A {\n'
          '  var z;\n'
          '  inc(int x) => ++x;\n'
          '}\n',
          'class A {\n'
          '  var z;\n'
          '  inc(int x) => ++x;\n'
          '}\n'
        );
    });

    test('CU (2)', () {
      expectCUFormatsTo(
          'class      A  {  \n'
          '}\n',
          'class A {\n'
          '}\n'
        );
    });

    test('CU (3)', () {
      expectCUFormatsTo(
          'class A {\n'
          '  }',
          'class A {\n'
          '}\n'
        );
    });

    test('CU (4)', () {
      expectCUFormatsTo(
          ' class A {\n'
          '}\n',
          'class A {\n'
          '}\n'
        );
    });

    test('CU (5)', () {
      expectCUFormatsTo(
          'class A  { int meaningOfLife() => 42; }',
          'class A {\n'
          '  int meaningOfLife() => 42;\n'
          '}\n'
      );
    });

    test('CU - EOL comments', () {
      expectCUFormatsTo(
          '//comment one\n\n'
          '//comment two\n\n',
          '//comment one\n\n'
          '//comment two\n\n'
      );
      expectCUFormatsTo(
          'var x;   //x\n',
          'var x; //x\n'
      );
      expectCUFormatsTo(
          'library foo;\n'
          '\n'
          '//comment one\n'
          '\n'
          'class C {\n'
          '}\n',
          'library foo;\n'
          '\n'
          '//comment one\n'
          '\n'
          'class C {\n'
          '}\n'
      );
      expectCUFormatsTo(
          'library foo;\n'
          '\n'
          '//comment one\n'
          '\n'
          '//comment two\n'
          '\n'
          'class C {\n'
          '}\n',
          'library foo;\n'
          '\n'
          '//comment one\n'
          '\n'
          '//comment two\n'
          '\n'
          'class C {\n'
          '}\n'
      );
      expectCUFormatsTo(
          'main() {\n'
          '//  print(1);\n'
          '//  print(2);\n'
          '  print(3);\n'
          '}\n',
          'main() {\n'
          '//  print(1);\n'
          '//  print(2);\n'
          '  print(3);\n'
          '}\n'
      );
      expectCUFormatsTo(
          'class A {\n'
          '//  int a;\n'
          '//  int b;\n'
          '  int c;\n'
          '}\n',
          'class A {\n'
          '//  int a;\n'
          '//  int b;\n'
          '  int c;\n'
          '}\n'
      );
    });

    test('CU - nested functions', () {
      expectCUFormatsTo(
          'x() {\n'
          '  y() {\n'
          '  }\n'
          '}\n',
          'x() {\n'
          '  y() {\n'
          '  }\n'
          '}\n'
        );
    });

    test('CU - top level', () {
      expectCUFormatsTo(
          '\n\n'
          'foo() {\n'
          '}\n'
          'bar() {\n'
          '}\n',
          '\n\n'
          'foo() {\n'
          '}\n'
          'bar() {\n'
          '}\n'
      );
      expectCUFormatsTo(
          'const A = 42;\n'
          'final foo = 32;\n',
          'const A = 42;\n'
          'final foo = 32;\n'
      );
    });

    test('CU - imports', () {
      expectCUFormatsTo(
          'import "dart:io";\n\n'
          'import "package:unittest/unittest.dart";\n'
          'foo() {\n'
          '}\n',
          'import "dart:io";\n\n'
          'import "package:unittest/unittest.dart";\n'
          'foo() {\n'
          '}\n'
      );
      expectCUFormatsTo(
          'library a; class B { }',
          'library a;\n'
          'class B {}\n'
      );
    });

    test('CU - method invocations', () {
      expectCUFormatsTo(
          'class A {\n'
          '  foo() {\n'
          '    bar();\n'
          '    for (int i = 0; i < 42; i++) {\n'
          '      baz();\n'
          '    }\n'
          '  }\n'
          '}\n',
          'class A {\n'
          '  foo() {\n'
          '    bar();\n'
          '    for (int i = 0; i < 42; i++) {\n'
          '      baz();\n'
          '    }\n'
          '  }\n'
          '}\n'
        );
    });

    test('CU w/class decl comment', () {
      expectCUFormatsTo(
          'import "foo";\n\n'
          '//Killer class\n'
          'class A {\n'
          '}',
          'import "foo";\n\n'
          '//Killer class\n'
          'class A {\n'
          '}\n'
        );
    });

    test('CU (method body)', () {
      expectCUFormatsTo(
          'class A {\n'
          '  foo(path) {\n'
          '    var buffer = new StringBuffer();\n'
          '    var file = new File(path);\n'
          '    return file;\n'
          '  }\n'
          '}\n',
          'class A {\n'
          '  foo(path) {\n'
          '    var buffer = new StringBuffer();\n'
          '    var file = new File(path);\n'
          '    return file;\n'
          '  }\n'
          '}\n'
      );
      expectCUFormatsTo(
          'class A {\n'
          '  foo(files) {\n'
          '    for (var  file in files) {\n'
          '      print(file);\n'
          '    }\n'
          '  }\n'
          '}\n',
          'class A {\n'
          '  foo(files) {\n'
          '    for (var file in files) {\n'
          '      print(file);\n'
          '    }\n'
          '  }\n'
          '}\n'
      );
    });

    test('CU (method indent)', () {
      expectCUFormatsTo(
          'class A {\n'
          'void x(){\n'
          '}\n'
          '}\n',
          'class A {\n'
          '  void x() {\n'
          '  }\n'
          '}\n'
      );
    });

    test('CU (method indent - 2)', () {
      expectCUFormatsTo(
          'class A {\n'
          ' static  bool x(){\n'
          'return true; }\n'
          ' }\n',
          'class A {\n'
          '  static bool x() {\n'
          '    return true;\n'
          '  }\n'
          '}\n'
        );
    });

    test('CU (method indent - 3)', () {
      expectCUFormatsTo(
          'class A {\n'
          ' int x() =>   42   + 3 ;  \n'
          '   }\n',
          'class A {\n'
          '  int x() => 42 + 3;\n'
          '}\n'
        );
    });

    test('CU (method indent - 4)', () {
      expectCUFormatsTo(
          'class A {\n'
          ' int x() { \n'
          'if (true) {\n'
          'return 42;\n'
          '} else {\n'
          'return 13;\n }\n'
          '   }'
          '}\n',
          'class A {\n'
          '  int x() {\n'
          '    if (true) {\n'
          '      return 42;\n'
          '    } else {\n'
          '      return 13;\n'
          '    }\n'
          '  }\n'
          '}\n'
        );
    });

    test('CU (multiple members)', () {
      expectCUFormatsTo(
          'class A {\n'
          '}\n'
          'class B {\n'
          '}\n',
          'class A {\n'
          '}\n'
          'class B {\n'
          '}\n'
        );
    });

    test('CU (multiple members w/blanks)', () {
      expectCUFormatsTo(
          'class A {\n'
          '}\n\n'
          'class B {\n\n\n'
          '  int b() => 42;\n\n'
          '  int c() => b();\n\n'
          '}\n',
          'class A {\n'
          '}\n\n'
          'class B {\n\n\n'
          '  int b() => 42;\n\n'
          '  int c() => b();\n\n'
          '}\n'
      );
    });

    test('CU - Block comments', () {
      expectCUFormatsTo(
          '/** Old school class comment */\n'
          'class C {\n'
          '  /** Foo! */ int foo() => 42;\n'
          '}\n',
          '/** Old school class comment */\n'
          'class C {\n'
          '  /** Foo! */\n'
          '  int foo() => 42;\n'
          '}\n'
      );
      expectCUFormatsTo(
          'library foo;\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n',
          'library foo;\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n'
      );
      expectCUFormatsTo(
          'library foo;\n'
          '/* A long\n'
          ' * Comment\n'
          '*/\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n',
          'library foo;\n'
          '/* A long\n'
          ' * Comment\n'
          '*/\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n'
      );
      expectCUFormatsTo(
          'library foo;\n'
          '/* A long\n'
          ' * Comment\n'
          '*/\n'
          '\n'
          '/* And\n'
          ' * another...\n'
          '*/\n'
          '\n'
          '// Mixing it up\n'
          '\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n',
          'library foo;\n'
          '/* A long\n'
          ' * Comment\n'
          '*/\n'
          '\n'
          '/* And\n'
          ' * another...\n'
          '*/\n'
          '\n'
          '// Mixing it up\n'
          '\n'
          'class C /* is cool */ {\n'
          '  /* int */ foo() => 42;\n'
          '}\n'
      );
      expectCUFormatsTo(
          '/// Copyright info\n'
          '\n'
          'library foo;\n'
          '/// Class comment\n'
          '//TODO: implement\n'
          'class C {\n'
          '}\n',
          '/// Copyright info\n'
          '\n'
          'library foo;\n'
          '/// Class comment\n'
          '//TODO: implement\n'
          'class C {\n'
          '}\n'
      );
    });

    test('CU - mixed comments', () {
      expectCUFormatsTo(
          'library foo;\n'
          '\n'
          '\n'
          '/* Comment 1 */\n'
          '\n'
          '// Comment 2\n'
          '\n'
          '/* Comment 3 */',
          'library foo;\n'
          '\n'
          '\n'
          '/* Comment 1 */\n'
          '\n'
          '// Comment 2\n'
          '\n'
          '/* Comment 3 */\n'
        );
    });

    test('CU - comments (EOF)', () {
      expectCUFormatsTo(
          'library foo; //zamm',
          'library foo; //zamm\n' //<-- note extra NEWLINE
        );
    });

    test('CU - comments (0)', () {
      expectCUFormatsTo(
          'library foo; //zamm\n'
          '\n'
          'class A {\n'
          '}\n',
          'library foo; //zamm\n'
          '\n'
          'class A {\n'
          '}\n'
        );
    });

    test('CU - comments (1)', () {
      expectCUFormatsTo(
          '/* foo */ /* bar */\n',
          '/* foo */ /* bar */\n'
      );
    });

    test('CU - comments (2)', () {
      expectCUFormatsTo(
          '/** foo */ /** bar */\n',
          '/** foo */\n'
          '/** bar */\n'
      );
    });

    test('CU - comments (3)', () {
      expectCUFormatsTo(
          'var x;   //x\n',
          'var x; //x\n'
      );
    });

    test('CU - comments (4)', () {
      expectCUFormatsTo(
          'class X { //X!\n'
          '}',
          'class X { //X!\n'
          '}\n'
      );
    });

    test('CU - comments (5)', () {
      expectCUFormatsTo(
          '//comment one\n\n'
          '//comment two\n\n',
          '//comment one\n\n'
          '//comment two\n\n'
      );
    });

    test('CU - comments (6)', () {
      expectCUFormatsTo(
          'var x;   //x\n',
          'var x; //x\n'
      );
    });

    test('CU - comments (6)', () {
      expectCUFormatsTo(
          'var /* int */ x; //x\n',
          'var /* int */ x; //x\n'
      );
    });

    test('CU - comments (7)', () {
      expectCUFormatsTo(
          'library foo;\n'
          '\n'
          '/// Docs\n'
          '/// spanning\n'
          '/// lines.\n'
          'class A {\n'
          '}\n'
          '\n'
          '/// ... and\n'
          '\n'
          '/// Dangling ones too\n'
          'int x;\n',
          'library foo;\n'
          '\n'
          '/// Docs\n'
          '/// spanning\n'
          '/// lines.\n'
          'class A {\n'
          '}\n'
          '\n'
          '/// ... and\n'
          '\n'
          '/// Dangling ones too\n'
          'int x;\n'
        );
    });

    test('CU - comments (8)', () {
      expectCUFormatsTo(
          'var x /* X */, y;\n',
          'var x /* X */, y;\n'
      );
    });

    test('CU - comments (9)', () {
      expectCUFormatsTo(
          'main() {\n'
          '  foo(1 /* bang */, 2);\n'
          '}\n'
          'foo(x, y) => null;\n',
          'main() {\n'
          '  foo(1 /* bang */, 2);\n'
          '}\n'
          'foo(x, y) => null;\n'
      );
    });

    test('CU - comments (10)', () {
      expectCUFormatsTo(
          'var l = [1 /* bang */, 2];\n',
          'var l = [1 /* bang */, 2];\n'
      );
    });

    test('CU - EOF nl', () {
      expectCUFormatsTo(
          'var x = 1;',
          'var x = 1;\n'
      );
    });

    test('CU - constructor', () {
      expectCUFormatsTo(
          'class A {\n'
          '  const _a;\n'
          '  A();\n'
          '  int a() => _a;\n'
          '}\n',
          'class A {\n'
          '  const _a;\n'
          '  A();\n'
          '  int a() => _a;\n'
          '}\n'
        );
    });

    test('CU - method decl w/ named params', () {
      expectCUFormatsTo(
          'class A {\n'
          '  int a(var x, {optional: null}) => null;\n'
          '}\n',
          'class A {\n'
          '  int a(var x, {optional: null}) => null;\n'
          '}\n'
        );
    });

    test('CU - method decl w/ optional params', () {
      expectCUFormatsTo(
          'class A {\n'
          '  int a(var x, [optional = null]) => null;\n'
          '}\n',
          'class A {\n'
          '  int a(var x, [optional = null]) => null;\n'
          '}\n'
        );
    });

    test('CU - factory constructor redirects', () {
      expectCUFormatsTo(
          'class A {\n'
          '  const factory A() = B;\n'
          '}\n',
          'class A {\n'
          '  const factory A() = B;\n'
          '}\n'
        );
    });

    test('CU - constructor auto field inits', () {
      expectCUFormatsTo(
          'class A {\n'
          '  int _a;\n'
          '  A(this._a);\n'
          '}\n',
          'class A {\n'
          '  int _a;\n'
          '  A(this._a);\n'
          '}\n'
        );
    });

    test('CU - parts', () {
      expectCUFormatsTo(
        'part of foo;',
        'part of foo;\n'
      );
    });

    test('CU (cons inits)', () {
      expectCUFormatsTo(
          'class X {\n'
          '  var x, y;\n'
          '  X() : x = 1, y = 2;\n'
          '}\n',
          'class X {\n'
          '  var x, y;\n'
          '  X()\n'
          '      : x = 1,\n'
          '        y = 2;\n'
          '}\n'
      );
    });

    test('CU async', () {
      expectCUFormatsTo(
          'main()\n'
          '    async  {\n'
          '  var x = ()   async=> 1;\n'
          '  y()async  {}\n'
          '  var z = ()\n'
          ' async\n'
          '     {};\n'
          '}\n',
          'main() async {\n'
          '  var x = () async => 1;\n'
          '  y() async {}\n'
          '  var z = () async {};\n'
          '}\n'
      );
    });

    test('stmt', () {
      expectStmtFormatsTo(
         'if (true){\n'
         'if (true){\n'
         'if (true){\n'
         'return true;\n'
         '} else{\n'
         'return false;\n'
         '}\n'
         '}\n'
         '}else{\n'
         'return false;\n'
         '}',
         'if (true) {\n'
         '  if (true) {\n'
         '    if (true) {\n'
         '      return true;\n'
         '    } else {\n'
         '      return false;\n'
         '    }\n'
         '  }\n'
         '} else {\n'
         '  return false;\n'
         '}'
      );
    });

    test('stmt (switch)', () {
      expectStmtFormatsTo(
        'switch (fruit) {\n'
        'case "apple":\n'
        'print("delish");\n'
        'break;\n'
        'case "fig":\n'
        'print("bleh");\n'
        'break;\n'
        '}',
        'switch (fruit) {\n'
        '  case "apple":\n'
        '    print("delish");\n'
        '    break;\n'
        '  case "fig":\n'
        '    print("bleh");\n'
        '    break;\n'
        '}'
      );
    });

    test('stmt (empty while body)', () {
      expectStmtFormatsTo(
        'while (true);',
        'while (true);'
      );
    });

    test('stmt (empty for body)', () {
      expectStmtFormatsTo(
        'for ( ; ; );',
        'for ( ; ; );'
      );
    });

    test('stmt (cascades)', () {
      expectStmtFormatsTo(
        '"foo"\n'
        '..toString()\n'
        '..toString();',
        '"foo"\n'
        '    ..toString()\n'
        '    ..toString();'
      );
    });

    test('stmt (generics)', () {
      expectStmtFormatsTo(
        'var numbers = <int>[1, 2, (3 + 4)];',
        'var numbers = <int>[1, 2, (3 + 4)];'
      );
    });

    test('stmt (try/catch)', () {
      expectStmtFormatsTo(
        'try {\n'
        'doSomething();\n'
        '} catch (e) {\n'
        'print(e);\n'
        '}',
        'try {\n'
        '  doSomething();\n'
        '} catch (e) {\n'
        '  print(e);\n'
        '}'
      );
      expectStmtFormatsTo(
          'try{\n'
          'doSomething();\n'
          '}on Exception catch (e){\n'
          'print(e);\n'
          '}',
          'try {\n'
          '  doSomething();\n'
          '} on Exception catch (e) {\n'
          '  print(e);\n'
          '}'
      );
    });

    test('stmt (binary/ternary ops)', () {
      expectStmtFormatsTo(
        'var a = 1 + 2 / (3 * -b);',
        'var a = 1 + 2 / (3 * -b);'
      );
      expectStmtFormatsTo(
        'var c = !condition == a > b;',
        'var c = !condition == a > b;'
      );
      expectStmtFormatsTo(
        'var d = condition ? b : object.method(a, b, c);',
        'var d = condition ? b : object.method(a, b, c);'
      );
      expectStmtFormatsTo(
        'var d = obj is! SomeType;',
        'var d = obj is! SomeType;'
      );
    });

    test('stmt (for in)', () {
      expectStmtFormatsTo(
        'for (Foo foo in bar.foos) {\n'
        '  print(foo);\n'
        '}',
        'for (Foo foo in bar.foos) {\n'
        '  print(foo);\n'
        '}'
      );
      expectStmtFormatsTo(
        'for (final Foo foo in bar.foos) {\n'
        '  print(foo);\n'
        '}',
        'for (final Foo foo in bar.foos) {\n'
        '  print(foo);\n'
        '}'
      );
      expectStmtFormatsTo(
        'for (final foo in bar.foos) {\n'
        '  print(foo);\n'
        '}',
        'for (final foo in bar.foos) {\n'
        '  print(foo);\n'
        '}'
      );
    });

    test('Statement (if)', () {
      expectStmtFormatsTo('if (true) print("true!");',
                          'if (true) print("true!");');
      expectStmtFormatsTo('if (true) { print("true!"); }',
                          'if (true) {\n'
                          '  print("true!");\n'
                          '}');
      // TODO(rnystrom): How should this be handled? Newline before else?
      expectStmtFormatsTo('if (true) print("true!"); else print("false!");',
                          'if (true) print("true!"); else print("false!");');
    });

    // smoketest to ensure we're enforcing the 'no gratuitous linebreaks'
    // opinion
    test('CU (eat newlines)', () {
      expectCUFormatsTo(
        'abstract\n'
        'class\n'
        'A{}',
        'abstract class A {}\n'
      );
    });

    test('initialIndent', () {
      var formatter = new CodeFormatter(
          new FormatterOptions(initialIndentationLevel: 2));
      var formattedSource =
          formatter.format(CodeKind.STATEMENT, 'var x;').source;
      expect(formattedSource, startsWith('    '));
    });

    test('selections', () {
      expectSelectedPostFormat('class X {}', '}');
      expectSelectedPostFormat('class X{}', '{');
      expectSelectedPostFormat('class X{int y;}', ';');
      expectSelectedPostFormat('class X{int y;}', '}');
      expectSelectedPostFormat('class X {}', ' {');
    });
  });

  /// Token streams
  group('token streams', () {
    test('string tokens', () {
      expectTokenizedEqual('class A{}', 'class A{ }');
      expectTokenizedEqual('class A{}', 'class A{\n  }\n');
      expectTokenizedEqual('class A {}', 'class A{ }');
      expectTokenizedEqual('  class A {}', 'class A{ }');
    });

    test('string tokens - w/ comments', () {
      expectTokenizedEqual('//foo\nint bar;', '//foo\nint bar;');
      expectTokenizedNotEqual('int bar;', '//foo\nint bar;');
      expectTokenizedNotEqual('//foo\nint bar;', 'int bar;');
    });

    test('INDEX', () {
      /// '[' ']' => '[]'
      var t1 = openSqBracket()..setNext(closeSqBracket()..setNext(eof()));
      var t2 = index()..setNext(eof());
      expectStreamsEqual(t1, t2);
    });

    test('GT_GT', () {
      /// '>' '>' => '>>'
      var t1 = gt()..setNext(gt()..setNext(eof()));
      var t2 = gt_gt()..setNext(eof());
      expectStreamsEqual(t1, t2);
    });

    test('t1 < t2', () {
      var t1 = string('foo')..setNext(eof());
      var t2 = string('foo')..setNext(string('bar')..setNext(eof()));
      expectStreamsNotEqual(t1, t2);
    });

    test('t1 > t2', () {
      var t1 = string('foo')..setNext(string('bar')..setNext(eof()));
      var t2 = string('foo')..setNext(eof());
      expectStreamsNotEqual(t1, t2);
    });
  });
}

Token closeSqBracket() => new Token(TokenType.CLOSE_SQUARE_BRACKET, 0);

Token eof() => new Token(TokenType.EOF, 0);

Token gt() => new Token(TokenType.GT, 0);

Token gt_gt() => new Token(TokenType.GT_GT, 0);

Token index() => new Token(TokenType.INDEX, 0);

Token openSqBracket() => new BeginToken(TokenType.OPEN_SQUARE_BRACKET, 0);

Token string(String lexeme) => new StringToken(TokenType.STRING, lexeme, 0);

FormattedSource formatCU(src, {selection}) =>
    new CodeFormatter().format(
        CodeKind.COMPILATION_UNIT, src, selection: selection);

String formatStatement(src) =>
    new CodeFormatter().format(CodeKind.STATEMENT, src).source;

Token tokenize(String str) {
  var reader = new CharSequenceReader(str);
  return new Scanner(null, reader, null).tokenize();
}

expectSelectedPostFormat(src, token) {
  var preOffset = src.indexOf(token);
  var length = token.length;
  var formatted = formatCU(src, selection: new Selection(preOffset, length));
  var postOffset = formatted.selection.offset;
  expect(formatted.source.substring(postOffset, postOffset + length),
      equals(src.substring(preOffset, preOffset + length)));
}

expectTokenizedEqual(String s1, String s2) =>
    expectStreamsEqual(tokenize(s1), tokenize(s2));

expectTokenizedNotEqual(String s1, String s2) =>
    expect(()=> expectStreamsEqual(tokenize(s1), tokenize(s2)),
    throwsA(new isInstanceOf<FormatterException>()));

expectStreamsEqual(Token t1, Token t2) =>
    new TokenStreamComparator(null, t1, t2).verifyEquals();

expectStreamsNotEqual(Token t1, Token t2) =>
    expect(() => new TokenStreamComparator(null, t1, t2).verifyEquals(),
    throwsA(new isInstanceOf<FormatterException>()));

expectCUFormatsTo(src, expected) =>
    expect(formatCU(src).source, equals(expected));

expectStmtFormatsTo(src, expected) =>
    expect(formatStatement(src), equals(expected));

runTests(testFileName, expectClause(String input, String output)) {
  group(testFileName, () {
    var testFile = new File(p.join(testDataDir, testFileName));
    var lines = testFile.readAsLinesSync();

    for (var i = 1; i < lines.length; ++i) {
      var startLine = i;

      var input = '';
      while (!lines[i].startsWith('<<<')) {
        input += lines[i++] + '\n';
      }

      var expectedOutput = '';
      while (++i < lines.length && !lines[i].startsWith('>>>')) {
        expectedOutput += lines[i] + '\n';
      }

      test("line $startLine", () {
        expectClause(input, expectedOutput);
      });
    }
  });
}

void testDirectory(String name) {
  var dir = p.join(p.dirname(p.fromUri(Platform.script)), name);
  for (var entry in new Directory(dir).listSync()) {
    if (!entry.path.endsWith(".stmt") &&
        !entry.path.endsWith(".unit")) {
      continue;
    }

    group("$name ${p.basename(entry.path)}", () {
      var lines = (entry as File).readAsLinesSync();

      // The first line has a "|" to indicate the page width.
      var pageWidth = lines[0].indexOf("|");
      var options = new FormatterOptions(pageWidth: pageWidth);
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
          print("SKIPPING $description");
          continue;
        }

        test(description, () {
          var formatter = new CodeFormatter(options);

          var result;
          if (p.extension(entry.path) == ".stmt") {
            result = formatter.format(CodeKind.STATEMENT, input).source + "\n";
          } else {
            result = formatter.format(CodeKind.COMPILATION_UNIT, input).source;
          }

          expect(result, equals(expectedOutput));
        });
      }
    });
  }
}
