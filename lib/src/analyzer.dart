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
import 'profile.dart';
import 'source_code.dart';

// TODO: Allow this to be configured.
final analyzer.ResourceProvider resourceProvider =
    analyzer.PhysicalResourceProvider.INSTANCE;

Future<void> formatPaths(FormatterOptions options, List<String> paths) async {
  Profile.begin('formatPaths()');

  Profile.begin('list files');
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
  Profile.end('list files');

  Profile.begin('analyzer create context collection');
  var collection = analyzer.AnalysisContextCollection(
    includedPaths: filesToFormat.map((r) => r.$1).toList(),
  );
  Profile.end('analyzer create context collection');

  for (var (path, displayPath) in filesToFormat) {
    await _processFile(collection, options, path, displayPath: displayPath);
  }

  await collection.dispose();

  Profile.end('formatPaths()');
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
  Profile.begin('analyzer _processFile()');
  displayPath ??= path;

  Profile.begin('analyzer get analysis options');
  var context = collection.contextFor(path);
  var analysisOptions = context.getAnalysisOptionsForFile(
    resourceProvider.getFile(path),
  );
  Profile.end('analyzer get analysis options');

  Profile.begin('analyzer get parsed unit');
  var session = context.currentSession;
  var parsedResult = session.getParsedUnit(path);

  if (parsedResult is! analyzer.ParsedUnitResult) {
    // TODO
    throw StateError('not parsed result');
  }

  Profile.end('analyzer get parsed unit');

  // Determine what language version to use.
  Profile.begin('analyzer get language version');
  // TODO: Use .effective?
  var languageVersion =
      options.languageVersion ?? parsedResult.unit.languageVersion.package;
  Profile.end('analyzer get language version');

  // Determine the configuration options.
  Profile.begin('analyzer get option values');
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
  Profile.end('analyzer get option values');

  var formatter = DartFormatter(
    languageVersion: languageVersion,
    indent: options.indent,
    pageWidth: pageWidth,
    trailingCommas: trailingCommas,
    experimentFlags: options.experimentFlags,
  );

  try {
    Profile.begin('analyzer get source string');
    var sourceString = resourceProvider.getFile(path).readAsStringSync();
    Profile.end('analyzer get source string');
    var source = SourceCode(sourceString, uri: path);
    options.beforeFile(path, displayPath);
    Profile.begin('format');
    SourceCode output;
    try {
      output = formatter.formatUnit(parsedResult);
    } finally {
      Profile.end('format');
    }
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
  } finally {
    Profile.end('analyzer _processFile()');
  }

  return false;
}
