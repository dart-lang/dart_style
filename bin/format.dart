import 'dart:io';

import 'package:args/args.dart';
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
      help: "Overwrite input files with formatted output.\n"
            "If unset, prints results to standard output.");
  parser.addFlag("follow-links", negatable: false,
      help: "Follow links to files and directories.\n"
            "If unset, links will be ignored.");
  parser.addFlag("machine", abbr: "m", negatable: false,
      help: "Produce machine-readable JSON output.");
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
    if (argResults[other]) {
      printUsage(parser,
          "Cannot use --$chosen and --$other at the same time.");
      exitCode = 64;
      return;
    }
  }

  var reporter = OutputReporter.print;
  if (argResults["dry-run"]) {
    checkForReporterCollision("dry-run", "overwrite");
    checkForReporterCollision("dry-run", "machine");

    reporter = OutputReporter.dryRun;
  } else if (argResults["overwrite"]) {
    checkForReporterCollision("overwrite", "machine");

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

  if (argResults.rest.isEmpty) {
    printUsage(parser,
        "Please provide at least one directory or file to format.");
    exitCode = 64;
    return;
  }

  var options = new FormatterOptions(reporter,
      pageWidth: pageWidth, followLinks: followLinks);

  for (var path in argResults.rest) {
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

Usage: dartformat [-w] <files or directories...>

${parser.usage}
""");
}
