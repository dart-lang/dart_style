import 'dart:io' as io;

import 'package:analyzer/dart/analysis/analysis_context_collection.dart'
    as analyzer;
import 'package:analyzer/dart/analysis/formatter_options.dart' as analyzer;
import 'package:analyzer/dart/analysis/results.dart' as analyzer;
import 'package:analyzer/file_system/file_system.dart' as analyzer;
import 'package:analyzer/file_system/physical_file_system.dart' as analyzer;
import 'package:path/path.dart' as p;

import 'cli/formatter_options.dart';
import 'dart_formatter.dart';
import 'exceptions.dart';
import 'source_code.dart';

// TODO: Allow this to be configured.
final analyzer.ResourceProvider resourceProvider =
    analyzer.PhysicalResourceProvider.INSTANCE;

Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  var filesToFormat = <(String, String)>[];

  for (var path in paths) {
    var directory = io.Directory(path);
    if (directory.existsSync()) {
      var entries = directory.listSync(
        recursive: true,
        followLinks: options.followLinks,
      );
      entries.sort((a, b) => a.path.compareTo(b.path));

      for (var entry in entries) {
        if (entry is io.Link) continue;
        if (entry is! io.File || !entry.path.endsWith('.dart')) continue;

        // If the path is in a subdirectory starting with ".", ignore it.
        var parts = p.split(p.relative(entry.path, from: directory.path));
        if (parts.any((part) => part.startsWith('.'))) continue;

        filesToFormat.add((p.normalize(p.absolute(entry.path)), entry.path));
      }
    } else {
      var file = io.File(path);
      if (file.existsSync()) {
        filesToFormat.add((p.normalize(p.absolute(file.path)), file.path));
      } else {
        io.stderr.writeln('No file or directory found at "$path".');
      }
    }
  }

  var collection = analyzer.AnalysisContextCollection(
    includedPaths: filesToFormat.map((r) => r.$1).toList(),
  );

  print('Should format ${filesToFormat.length}');

  for (var (path, displayPath) in filesToFormat) {
    await _processFile(collection, options, path, displayPath: displayPath);
  }

  await collection.dispose();
}

/// Runs the formatter on [file].
///
/// Returns `true` if successful or `false` if an error occurred.
Future<bool> _processFile(
  analyzer.AnalysisContextCollection collection,
  FormatterOptions options,
  String path, {
  String? displayPath,
}) async {
  displayPath ??= path;

  var context = collection.contextFor(path);
  var analysisOptions = context.getAnalysisOptionsForFile(
    resourceProvider.getFile(path),
  );

  var session = context.currentSession;
  var parsedResult = session.getParsedUnit(path);

  if (parsedResult is! analyzer.ParsedUnitResult) {
    // TODO
    throw StateError('not parsed result');
  }

  // Determine what language version to use.
  // TODO: Use .effective?
  var languageVersion =
      options.languageVersion ?? parsedResult.unit.languageVersion.package;

  // Determine the configuration options.
  var pageWidth =
      options.pageWidth ?? analysisOptions.formatterOptions.pageWidth;
  var trailingCommas =
      options.trailingCommas ??
      switch (analysisOptions.formatterOptions.trailingCommas) {
        null => TrailingCommas.automate,
        analyzer.TrailingCommas.automate => TrailingCommas.automate,
        analyzer.TrailingCommas.preserve => TrailingCommas.preserve,
      };

  // Use a default page width if we don't have a specified one and couldn't
  // find a configured one.
  pageWidth ??= DartFormatter.defaultPageWidth;

  var formatter = DartFormatter(
    languageVersion: languageVersion,
    indent: options.indent,
    pageWidth: pageWidth,
    trailingCommas: trailingCommas,
    experimentFlags: options.experimentFlags,
  );

  try {
    var source = SourceCode(
      resourceProvider.getFile(path).readAsStringSync(),
      uri: path,
    );
    options.beforeFile(path, displayPath);
    var output = formatter.formatUnit(parsedResult);
    options.afterFile(
      path,
      formatter,
      displayPath,
      output,
      changed: source.text != output.text,
    );
    return true;
  } on FormatterException catch (err) {
    var color =
        io.Platform.operatingSystem != 'windows' &&
        io.stdioType(io.stderr) == io.StdioType.terminal;

    io.stderr.writeln(err.message(color: color));
  } on UnexpectedOutputException catch (err) {
    io.stderr.writeln(
      '''Hit a bug in the formatter when formatting $displayPath.
$err
Please report at github.com/dart-lang/dart_style/issues.''',
    );
  } catch (err, stack) {
    io.stderr.writeln(
      '''Hit a bug in the formatter when formatting $displayPath.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''',
    );
  }

  return false;
}
