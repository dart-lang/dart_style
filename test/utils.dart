// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.utils;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import 'package:dart_style/dart_style.dart';

const unformattedSource = 'void  main()  =>  print("hello") ;';
const formattedSource = 'void main() => print("hello");\n';

final _indentPattern = RegExp(r"\(indent (\d+)\)");
final _fixPattern = RegExp(r"\(fix ([a-x-]+)\)");

/// Runs the command line formatter, passing it [args].
Future<TestProcess> runFormatter([List<String> args]) {
  if (args == null) args = [];

  // Locate the "test" directory. Use mirrors so that this works with the test
  // package, which loads this suite into an isolate.
  var testDir = p.dirname(currentMirrorSystem()
      .findLibrary(#dart_style.test.utils)
      .uri
      .toFilePath());

  var formatterPath = p.normalize(p.join(testDir, "../bin/format.dart"));

  args.insert(0, formatterPath);

  // Use the same package root, if there is one.
  if (Platform.packageConfig != null && Platform.packageConfig.isNotEmpty) {
    args.insert(0, "--packages=${Platform.packageConfig}");
  }

  return TestProcess.start(Platform.executable, args);
}

/// Runs the command line formatter, passing it the test directory followed by
/// [args].
Future<TestProcess> runFormatterOnDir([List<String> args]) {
  if (args == null) args = [];
  return runFormatter([d.sandbox]..addAll(args));
}

/// Run tests defined in "*.unit" and "*.stmt" files inside directory [name].
void testDirectory(String name, [Iterable<StyleFix> fixes]) {
  // Locate the "test" directory. Use mirrors so that this works with the test
  // package, which loads this suite into an isolate.
  var testDir = p.dirname(currentMirrorSystem()
      .findLibrary(#dart_style.test.utils)
      .uri
      .toFilePath());

  var entries = Directory(p.join(testDir, name))
      .listSync(recursive: true, followLinks: false);
  entries.sort((a, b) => a.path.compareTo(b.path));

  for (var entry in entries) {
    if (!entry.path.endsWith(".stmt") && !entry.path.endsWith(".unit")) {
      continue;
    }

    _testFile(name, entry.path, fixes);
  }
}

void testFile(String path, [Iterable<StyleFix> fixes]) {
  // Locate the "test" directory. Use mirrors so that this works with the test
  // package, which loads this suite into an isolate.
  var testDir = p.dirname(currentMirrorSystem()
      .findLibrary(#dart_style.test.utils)
      .uri
      .toFilePath());

  _testFile(p.dirname(path), p.join(testDir, path), fixes);
}

void _testFile(String name, String path, Iterable<StyleFix> baseFixes) {
  var fixes = <StyleFix>[];
  if (baseFixes != null) fixes.addAll(baseFixes);

  group("$name ${p.basename(path)}", () {
    // Explicitly create a File, in case the entry is a Link.
    var lines = File(path).readAsLinesSync();

    // The first line may have a "|" to indicate the page width.
    var pageWidth;
    if (lines[0].endsWith("|")) {
      pageWidth = lines[0].indexOf("|");
      lines = lines.skip(1).toList();
    }

    var i = 0;
    while (i < lines.length) {
      var description = lines[i++].replaceAll(">>>", "");

      // Let the test specify a leading indentation. This is handy for
      // regression tests which often come from a chunk of nested code.
      var leadingIndent = 0;
      description = description.replaceAllMapped(_indentPattern, (match) {
        leadingIndent = int.parse(match[1]);
        return "";
      });

      // Let the test specify fixes to apply.
      description = description.replaceAllMapped(_fixPattern, (match) {
        fixes.add(StyleFix.all.firstWhere((fix) => fix.name == match[1]));
        return "";
      });

      description = description.trim();

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

      // TODO(rnystrom): Stop skipping these tests when possible.
      if (description.contains("(skip:")) {
        print("skipping $description");
        continue;
      }

      test(description, () {
        var isCompilationUnit = p.extension(path) == ".unit";

        var inputCode =
            _extractSelection(input, isCompilationUnit: isCompilationUnit);

        var expected = _extractSelection(expectedOutput,
            isCompilationUnit: isCompilationUnit);

        var formatter = DartFormatter(
            pageWidth: pageWidth, indent: leadingIndent, fixes: fixes);

        var actual = formatter.formatSource(inputCode);

        // The test files always put a newline at the end of the expectation.
        // Statements from the formatter (correctly) don't have that, so add
        // one to line up with the expected result.
        var actualText = actual.text;
        if (!isCompilationUnit) actualText += "\n";

        // Fail with an explicit message because it's easier to read than
        // the matcher output.
        if (actualText != expected.text) {
          fail("Formatting did not match expectation. Expected:\n"
              "${expected.text}\nActual:\n$actualText");
        }

        expect(actual.selectionStart, equals(expected.selectionStart));
        expect(actual.selectionLength, equals(expected.selectionLength));
      });
    }
  });
}

/// Given a source string that contains ‹ and › to indicate a selection, returns
/// a [SourceCode] with the text (with the selection markers removed) and the
/// correct selection range.
SourceCode _extractSelection(String source, {bool isCompilationUnit = false}) {
  var start = source.indexOf("‹");
  source = source.replaceAll("‹", "");

  var end = source.indexOf("›");
  source = source.replaceAll("›", "");

  return SourceCode(source,
      isCompilationUnit: isCompilationUnit,
      selectionStart: start == -1 ? null : start,
      selectionLength: end == -1 ? null : end - start);
}
