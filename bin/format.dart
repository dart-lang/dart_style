// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_style/src/dart_formatter.dart';
import 'package:dart_style/src/formatter_exception.dart';
import 'package:dart_style/src/formatter_options.dart';
import 'package:dart_style/src/io.dart';

void main(List<String> args) {
  var parser = new ArgParser(allowTrailingOptions: true);

  parser.addFlag("help", abbr: "h", negatable: false,
      help: "Shows usage information.");
  parser.addOption("line-length", abbr: "l",
      help: "Wrap lines longer than this.",
      defaultsTo: "80");
  parser.addFlag("dry-run", abbr: "n", negatable: false,
      help: "Show which files would be modified but make no changes.");
  parser.addFlag("overwrite", abbr: "w", negatable: false,
      help: "Overwrite input files with formatted output.");
  parser.addFlag("machine", abbr: "m", negatable: false,
      help: "Produce machine-readable JSON output.");
  parser.addFlag("follow-links", negatable: false,
      help: "Follow links to files and directories.\n"
            "If unset, links will be ignored.");
  parser.addFlag("transform", abbr: "t", negatable: false,
      help: "Unused flag for compability with the old formatter.");

  var argResults;
  try {
    argResults = parser.parse(args);
  } on FormatException catch (err) {
    printUsage(parser, err.message);
    exitCode = 64;
    return;
  }

  if (argResults["help"]) {
    printUsage(parser);
    return;
  }

  if (argResults["dry-run"] && argResults["overwrite"]) {
    printUsage(parser,
        "Cannot use --dry-run and --overwrite at the same time.");
    exitCode = 64;
    return;
  }

  checkForReporterCollision(String chosen, String other) {
    if (!argResults[other]) return false;

    printUsage(parser,
        "Cannot use --$chosen and --$other at the same time.");
    exitCode = 64;
    return true;
  }

  var reporter = OutputReporter.print;
  if (argResults["dry-run"]) {
    if (checkForReporterCollision("dry-run", "overwrite")) return;
    if (checkForReporterCollision("dry-run", "machine")) return;

    reporter = OutputReporter.dryRun;
  } else if (argResults["overwrite"]) {
    if (checkForReporterCollision("overwrite", "machine")) return;

    if (argResults.rest.isEmpty) {
      printUsage(parser,
          "Cannot use --overwrite without providing any paths to format.");
      exitCode = 64;
      return;
    }

    reporter = OutputReporter.overwrite;
  } else if (argResults["machine"]) {
    reporter = OutputReporter.printJson;
  }

  var pageWidth;

  try {
    pageWidth = int.parse(argResults["line-length"]);
  } on FormatException catch (_) {
    printUsage(parser, '--line-length must be an integer, was '
                       '"${argResults['line-length']}".');
    exitCode = 64;
    return;
  }

  var followLinks = argResults["follow-links"];

  var options = new FormatterOptions(reporter,
      pageWidth: pageWidth, followLinks: followLinks);

  if (argResults.rest.isEmpty) {
    formatStdin(options);
  } else {
    formatPaths(options, argResults.rest);
  }
}

/// Reads input from stdin until it's closed, and the formats it.
void formatStdin(FormatterOptions options) {
  var input = new StringBuffer();
  stdin.transform(new Utf8Decoder()).listen(input.write, onDone: () {
    var formatter = new DartFormatter(pageWidth: options.pageWidth);
    try {
      var source = input.toString();
      var output = formatter.format(source, uri: "stdin");
      options.reporter.showFile(null, "<stdin>", output,
          changed: source != output);
      return true;
    } on FormatterException catch (err) {
      stderr.writeln(err.message());
    } catch (err, stack) {
      stderr.writeln('''Hit a bug in the formatter when formatting stdin.
Please report at: github.com/dart-lang/dart_style/issues
$err
$stack''');
    }
  });
}

/// Formats all of the files and directories given by [paths].
void formatPaths(FormatterOptions options, List<String> paths) {
  for (var path in paths) {
    var directory = new Directory(path);
    if (directory.existsSync()) {
      if (!processDirectory(options, directory)) {
        exitCode = 65;
      }
      continue;
    }

    var file = new File(path);
    if (file.existsSync()) {
      if (!processFile(options, file)) {
        exitCode = 65;
      }
    } else {
      stderr.writeln('No file or directory found at "$path".');
    }
  }
}

void printUsage(ArgParser parser, [String error]) {
  var output = stdout;

  var message = "Reformats whitespace in Dart source files.";
  if (error != null) {
    message = error;
    output = stdout;
  }

  output.write("""$message

Usage: dartfmt [-n|-w] [files or directories...]

${parser.usage}
""");
}
