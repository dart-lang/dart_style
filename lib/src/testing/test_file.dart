// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../dart_style.dart';

final _indentPattern = RegExp(r'\(indent (\d+)\)');
final _fixPattern = RegExp(r'\(fix ([a-x-]+)\)');
final _unicodeUnescapePattern = RegExp(r'×([0-9a-fA-F]{2,4})');
final _unicodeEscapePattern = RegExp('[\x0a\x0c\x0d]');

/// Get the absolute local file path to the dart_style package's root directory.
Future<String> findPackageDirectory() async {
  var libraryPath = (await Isolate.resolvePackageUri(
          Uri.parse('package:dart_style/src/testing/test_file.dart')))
      ?.toFilePath();

  // Fallback, if we can't resolve the package URI because we're running in an
  // AOT snapshot, just assume we're running from the root directory of the
  // package.
  libraryPath ??= 'lib/src/testing/test_file.dart';

  return p.normalize(p.join(p.dirname(libraryPath), '../../..'));
}

/// Get the absolute local file path to the package's "test" directory.
Future<String> findTestDirectory() async {
  return p.normalize(p.join(await findPackageDirectory(), 'test'));
}

/// A file containing a series of formatting tests.
class TestFile {
  /// Finds all test files in the given directory relative to the package's
  /// `test/` directory.
  static Future<List<TestFile>> listDirectory(String name) async {
    var testDir = await findTestDirectory();
    var entries = Directory(p.join(testDir, name))
        .listSync(recursive: true, followLinks: false);
    entries.sort((a, b) => a.path.compareTo(b.path));

    return [
      for (var entry in entries)
        if (entry is File &&
            (entry.path.endsWith('.stmt') || entry.path.endsWith('.unit')))
          TestFile._load(entry, p.relative(entry.path, from: testDir))
    ];
  }

  /// Reads the test file from [path], which is relative to the package's
  /// `test/` directory.
  static Future<TestFile> read(String path) async {
    var testDir = await findTestDirectory();
    var file = File(p.join(testDir, path));
    return TestFile._load(file, p.relative(file.path, from: testDir));
  }

  /// Reads the test file from [file].
  factory TestFile._load(File file, String relativePath) {
    var lines = file.readAsLinesSync();

    // The first line may have a "|" to indicate the page width.
    var i = 0;
    int? pageWidth;
    if (lines[i].endsWith('|')) {
      pageWidth = lines[i].indexOf('|');
      i++;
    }

    var tests = <FormatTest>[];

    List<String> readComments() {
      var comments = <String>[];
      while (lines[i].startsWith('###')) {
        comments.add(lines[i]);
        i++;
      }

      return comments;
    }

    String readLine() => lines[i++];

    var fileComments = readComments();

    while (i < lines.length) {
      var lineNumber = i + 1;
      var description = readLine().replaceAll('>>>', '');
      var fixes = <StyleFix>[];

      // Let the test specify a leading indentation. This is handy for
      // regression tests which often come from a chunk of nested code.
      var leadingIndent = 0;
      description = description.replaceAllMapped(_indentPattern, (match) {
        leadingIndent = int.parse(match[1]!);
        return '';
      });

      // Let the test specify fixes to apply.
      description = description.replaceAllMapped(_fixPattern, (match) {
        fixes.add(StyleFix.all.firstWhere((fix) => fix.name == match[1]));
        return '';
      });

      var inputComments = readComments();

      var inputBuffer = StringBuffer();
      while (i < lines.length) {
        var line = readLine();
        if (line.startsWith('<<<')) break;
        inputBuffer.writeln(line);
      }

      var outputDescription = lines[i - 1].replaceAll('<<<', '');

      var outputComments = readComments();

      var outputBuffer = StringBuffer();
      while (i < lines.length) {
        var line = readLine();
        if (line.startsWith('>>>')) {
          // Found another test, so roll back to the test description for the
          // next iteration through the loop.
          i--;
          break;
        }
        outputBuffer.writeln(line);
      }

      var isCompilationUnit = file.path.endsWith('.unit');
      var input = _extractSelection(_unescapeUnicode(inputBuffer.toString()),
          isCompilationUnit: isCompilationUnit);
      var output = _extractSelection(_unescapeUnicode(outputBuffer.toString()),
          isCompilationUnit: isCompilationUnit);

      tests.add(FormatTest(
          input,
          output,
          description.trim(),
          outputDescription.trim(),
          lineNumber,
          fixes,
          leadingIndent,
          inputComments,
          outputComments));
    }

    return TestFile._(relativePath, pageWidth, fileComments, tests);
  }

  TestFile._(this.path, this.pageWidth, this.comments, this.tests);

  /// The path to the test file, relative to the `test/` directory.
  final String path;

  /// The page width for tests in this file or `null` if the default should be
  /// used.
  final int? pageWidth;

  /// The `###` comment lines at the beginning of the test file before any
  /// tests.
  final List<String> comments;

  /// The tests in this file.
  final List<FormatTest> tests;

  bool get isCompilationUnit => path.endsWith('.unit');
}

/// A single formatting test inside a [TestFile].
class FormatTest {
  /// The unformatted input.
  final SourceCode input;

  /// The expected output.
  final SourceCode output;

  /// The optional description of the test.
  final String description;

  /// The `###` comment lines appearing after the test description before the
  /// input code.
  final List<String> inputComments;

  /// If there is a remark on the "<<<" line, this is it.
  final String outputDescription;

  /// The `###` comment lines appearing after the "<<<" before the output code.
  final List<String> outputComments;

  /// The 1-based index of the line where this test begins.
  final int line;

  /// The style fixes this test is applying.
  final List<StyleFix> fixes;

  /// The number of spaces of leading indentation that should be added to each
  /// line.
  final int leadingIndent;

  FormatTest(
      this.input,
      this.output,
      this.description,
      this.outputDescription,
      this.line,
      this.fixes,
      this.leadingIndent,
      this.inputComments,
      this.outputComments);

  /// The line and description of the test.
  String get label {
    if (description.isEmpty) return 'line $line';
    return 'line $line: $description';
  }
}

extension SourceCodeExtensions on SourceCode {
  /// If the source code has a selection, returns its text with `‹` and `›`
  /// inserted at the selection begin and end points.
  ///
  /// Otherwise, returns the code as-is.
  String get textWithSelectionMarkers {
    if (selectionStart == null) return text;
    return '$textBeforeSelection‹$selectedText›$textAfterSelection';
  }
}

/// Given a source string that contains ‹ and › to indicate a selection, returns
/// a [SourceCode] with the text (with the selection markers removed) and the
/// correct selection range.
SourceCode _extractSelection(String source, {bool isCompilationUnit = false}) {
  var start = source.indexOf('‹');
  source = source.replaceAll('‹', '');

  var end = source.indexOf('›');
  source = source.replaceAll('›', '');

  return SourceCode(source,
      isCompilationUnit: isCompilationUnit,
      selectionStart: start == -1 ? null : start,
      selectionLength: end == -1 ? null : end - start);
}

/// Turn the special Unicode escape marker syntax used in the tests into real
/// Unicode characters.
///
/// This does not use Dart's own string escape sequences so that we don't
/// accidentally modify the Dart code being formatted.
String _unescapeUnicode(String input) {
  return input.replaceAllMapped(_unicodeUnescapePattern, (match) {
    var codePoint = int.parse(match[1]!, radix: 16);
    return String.fromCharCode(codePoint);
  });
}

/// Turn the few Unicode characters used in tests back to their escape syntax.
String escapeUnicode(String input) {
  return input.replaceAllMapped(_unicodeEscapePattern, (match) {
    return '×${match[0]!.codeUnitAt(0).toRadixString(16)}';
  });
}
