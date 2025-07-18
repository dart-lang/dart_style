// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../source_code.dart';

final _indentPattern = RegExp(r'\(indent (\d+)\)');
final _experimentPattern = RegExp(r'\(experiment ([a-z-]+)\)');
final _preserveTrailingCommasPattern = RegExp(r'\(trailing_commas preserve\)');
final _unicodeUnescapePattern = RegExp(r'×([0-9a-fA-F]{2,4})');
final _unicodeEscapePattern = RegExp('[\x0a\x0c\x0d]');

/// Matches an output header line with an optional version and description.
/// Examples:
///
///    >>>
///    >>> Only description.
///    >>> 1.2
///    >>> 1.2 Version and description.
final _outputPattern = RegExp(r'<<<( (\d+)\.(\d+))?(.*)');

/// Get the absolute local file path to the dart_style package's root directory.
Future<String> findPackageDirectory() async {
  var libraryPath =
      (await Isolate.resolvePackageUri(
        Uri.parse('package:dart_style/src/testing/test_file.dart'),
      ))?.toFilePath();

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
final class TestFile {
  /// Finds all test files in the given directory relative to the package's
  /// `test/` directory.
  static Future<List<TestFile>> listDirectory(String name) async {
    var testDir = await findTestDirectory();
    var entries = Directory(
      p.join(testDir, name),
    ).listSync(recursive: true, followLinks: false);
    entries.sort((a, b) => a.path.compareTo(b.path));

    return [
      for (var entry in entries)
        if (entry is File &&
            (entry.path.endsWith('.stmt') || entry.path.endsWith('.unit')))
          TestFile._load(entry, p.relative(entry.path, from: testDir)),
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

    var isCompilationUnit = file.path.endsWith('.unit');

    // The first line may have a "|" to indicate the page width.
    var i = 0;
    int? pageWidth;
    if (lines[i].endsWith('|')) {
      pageWidth = lines[i].indexOf('|');
      i++;
    }

    // Optional line to configure options for all tests in the file.
    TestOptions fileOptions;
    if (!lines[i].startsWith('###') && !lines[i].startsWith('>>>')) {
      (fileOptions, _) = _parseOptions(lines[i]);
      i++;
    } else {
      fileOptions = TestOptions(null, null, const []);
    }

    var tests = <FormatTest>[];

    List<String> readComments() {
      var comments = <String>[];
      while (i < lines.length && lines[i].startsWith('###')) {
        comments.add(lines[i]);
        i++;
      }

      return comments;
    }

    String readLine() => lines[i++];

    var fileComments = readComments();

    while (i < lines.length) {
      var lineNumber = i + 1;
      var line = readLine().replaceAll('>>>', '');
      var (options, description) = _parseOptions(line);
      description = description.trim();

      var inputComments = readComments();
      var inputBuffer = StringBuffer();
      while (i < lines.length && !lines[i].startsWith('<<<')) {
        inputBuffer.writeln(readLine());
      }

      var inputCode = _extractSelection(
        _unescapeUnicode(inputBuffer.toString()),
        isCompilationUnit: isCompilationUnit,
      );

      var input = TestEntry(description, inputComments, inputCode);

      // Read the outputs. A single test should have outputs in one of two
      // forms:
      //
      // - One single unversioned output which is the expected output across
      //   all supported versions.
      // - One or more versioned outputs, each of which defines the expected
      //   output at that language version or later until reaching the next
      //   output's version.
      //
      // The parser here collects all of the outputs, versioned and unversioned
      // and then reports an error if the result is not one of those two styles.
      void fail(String error) {
        throw FormatException(
          'Test format error in $relativePath, line $lineNumber: $error',
        );
      }

      var unversionedOutputs = <TestEntry>[];
      var versionedOutputs = <Version, TestEntry>{};
      while (i < lines.length && lines[i].startsWith('<<<')) {
        var match = _outputPattern.firstMatch(readLine())!;
        var outputDescription = match[4]!;
        Version? outputVersion;
        if (match[1] != null) {
          outputVersion = Version(
            int.parse(match[2]!),
            int.parse(match[3]!),
            0,
          );
        }

        var outputComments = readComments();

        var outputBuffer = StringBuffer();
        while (i < lines.length &&
            !lines[i].startsWith('>>>') &&
            !lines[i].startsWith('<<<')) {
          var line = readLine();
          outputBuffer.writeln(line);
        }

        // The output always has a trailing newline. When formatting a
        // statement, the formatter (correctly) doesn't output trailing
        // newlines when formatting a statement, so remove it from the
        // expectation to match.
        var outputText = outputBuffer.toString();
        if (!isCompilationUnit) {
          assert(outputText.endsWith('\n'));
          outputText = outputText.substring(0, outputText.length - 1);
        }
        var outputCode = _extractSelection(
          _unescapeUnicode(outputText),
          isCompilationUnit: isCompilationUnit,
        );

        var entry = TestEntry(
          outputDescription.trim(),
          outputComments,
          outputCode,
        );
        if (outputVersion != null) {
          if (versionedOutputs.containsKey(outputVersion)) {
            fail('Multiple outputs with the same version $outputVersion.');
          }

          versionedOutputs[outputVersion] = entry;
        } else {
          unversionedOutputs.add(entry);
        }
      }

      switch ((unversionedOutputs.length, versionedOutputs.length)) {
        case (0, 0):
          fail('Test must have at least one output.');
        case (0, > 0):
          tests.add(
            VersionedFormatTest(lineNumber, options, input, versionedOutputs),
          );
        case (1, 0):
          tests.add(
            UnversionedFormatTest(
              lineNumber,
              options,
              input,
              unversionedOutputs.first,
            ),
          );
        case (> 1, 0):
          fail('Test can\'t have multiple unversioned outputs.');
        default:
          fail('Test can\'t have both versioned and unversioned outputs.');
      }
    }

    return TestFile._(
      relativePath,
      pageWidth,
      fileOptions,
      fileComments,
      tests,
    );
  }

  /// Parses all of the test option syntax like `(indent 3)` from [line].
  ///
  /// Returns the options and the text remaining on the line after the options
  /// are removed.
  static (TestOptions, String) _parseOptions(String line) {
    // Let the test specify a leading indentation. This is handy for
    // regression tests which often come from a chunk of nested code.
    int? leadingIndent;
    line = line.replaceAllMapped(_indentPattern, (match) {
      leadingIndent = int.parse(match[1]!);
      return '';
    });

    // Let the test enable experiments for features that are supported but not
    // released yet.
    var experiments = <String>[];
    line = line.replaceAllMapped(_experimentPattern, (match) {
      experiments.add(match[1]!);
      return '';
    });

    TrailingCommas? trailingCommas;
    line = line.replaceAllMapped(_preserveTrailingCommasPattern, (match) {
      trailingCommas = TrailingCommas.preserve;
      return '';
    });

    return (TestOptions(leadingIndent, trailingCommas, experiments), line);
  }

  TestFile._(
    this.path,
    this.pageWidth,
    this.options,
    this.comments,
    this.tests,
  );

  /// The path to the test file, relative to the `test/` directory.
  final String path;

  /// The page width for tests in this file or `null` if the default should be
  /// used.
  final int? pageWidth;

  /// The default options used by all tests in this file.
  final TestOptions options;

  /// The `###` comment lines at the beginning of the test file before any
  /// tests.
  final List<String> comments;

  /// The tests in this file.
  final List<FormatTest> tests;

  bool get isCompilationUnit => path.endsWith('.unit');

  /// Whether the test uses the tall or short style.
  bool get isTall => p.split(path).contains('tall');

  /// Creates a [DartFormatter] configured with all of the options that should
  /// be applied for [test] in this test file.
  ///
  /// If [version] is given, then it specifies the language version to run the
  /// test at. Otherwise, the test's default version is used.
  DartFormatter formatterForTest(FormatTest test, [Version? version]) {
    var defaultLanguageVersion =
        isTall
            ? DartFormatter.latestLanguageVersion
            : DartFormatter.latestShortStyleLanguageVersion;

    return DartFormatter(
      languageVersion: version ?? defaultLanguageVersion,
      pageWidth: pageWidth,
      indent: test.options.leadingIndent ?? options.leadingIndent ?? 0,
      experimentFlags: [
        ...options.experimentFlags,
        ...test.options.experimentFlags,
      ],
      trailingCommas:
          test.options.trailingCommas ??
          options.trailingCommas ??
          TrailingCommas.automate,
    );
  }
}

/// A single formatting test inside a [TestFile].
sealed class FormatTest {
  /// The 1-based index of the line where this test begins.
  final int line;

  /// The options specific to this test.
  final TestOptions options;

  /// The unformatted input.
  final TestEntry input;

  FormatTest(this.line, this.options, this.input);

  /// The line and description of the test.
  String get label {
    if (input.description.isEmpty) return 'line $line';
    return 'line $line: ${input.description}';
  }
}

/// A test for formatting that should be the same across all language versions.
///
/// Most tests are of this form.
final class UnversionedFormatTest extends FormatTest {
  /// The expected output.
  final TestEntry output;

  UnversionedFormatTest(super.line, super.options, super.input, this.output);
}

/// A test whose expected formatting changes at specific versions.
final class VersionedFormatTest extends FormatTest {
  /// The expected output by version.
  ///
  /// Each key is the lowest version where that output is expected. If there are
  /// supported versions lower than the lowest key here, then the test is not
  /// run on those versions at all. These tests represent new syntax that isn't
  /// supported in later versions. For example, if the map has only a single
  /// entry whose key is 3.8, then the test is skipped on 3.7, run at 3.8, and
  /// should be valid at any higher version.
  ///
  /// If there are multiple entries in the map, they represent versions where
  /// the formatting style has changed.
  final Map<Version, TestEntry> outputs;

  VersionedFormatTest(super.line, super.options, super.input, this.outputs);
}

/// A single test input or output.
final class TestEntry {
  /// Any remark on the "<<<" or ">>>" line.
  final String description;

  /// The `###` comment lines appearing after the header line before the code.
  final List<String> comments;

  final SourceCode code;

  TestEntry(this.description, this.comments, this.code);
}

/// Options for configuring all tests in a file or an individual test.
final class TestOptions {
  /// The number of spaces of leading indentation that should be added to each
  /// line.
  final int? leadingIndent;

  /// The trailing comma handling configuration.
  final TrailingCommas? trailingCommas;

  /// Experiments that should be enabled when running this test.
  final List<String> experimentFlags;

  TestOptions(this.leadingIndent, this.trailingCommas, this.experimentFlags);
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

  return SourceCode(
    source,
    isCompilationUnit: isCompilationUnit,
    selectionStart: start == -1 ? null : start,
    selectionLength: end == -1 ? null : end - start,
  );
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
