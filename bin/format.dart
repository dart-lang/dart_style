import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:dart_style/dart_style.dart';

bool overwrite = false;
int lineLength = 80;

void main(List<String> args) {
  var parser = new ArgParser();
  parser.addFlag("help", abbr: "h", negatable: false,
      help: "Shows usage information.");
  parser.addOption("line-length", abbr: "l",
      help: "Wrap lines longer than this.",
      defaultsTo: "80");
  parser.addFlag("overwrite", abbr: "w", negatable: false,
      help: "Overwrite input files with formatted output.\n"
            "If unset, prints results to standard output.");

  var options = parser.parse(args);

  if (options["help"]) {
    printUsage(parser);
    return;
  }

  overwrite = options["overwrite"];

  try {
    lineLength = int.parse(options["line-length"]);
  } on FormatException catch (_) {
    printUsage(parser, '--line-length must be an integer, was '
                       '"${options['line-length']}".');
    exitCode = 64;
    return;
  }

  if (options.rest.isEmpty) {
    printUsage(parser,
        "Please provide at least one directory or file to format.");
    exitCode = 64;
    return;
  }

  for (var path in options.rest) {
    var directory = new Directory(path);
    if (directory.existsSync()) {
      processDirectory(directory);
      continue;
    }

    var file = new File(path);
    if (file.existsSync()) {
      processFile(file);
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

Usage: dartfmt [-l <line length>] <files or directories...>

${parser.usage}
""");
}

/// Runs the formatter on every .dart file in [path] (and its subdirectories),
/// and replaces them with their formatted output.
void processDirectory(Directory directory) {
  print("Formatting directory ${directory.path}:");
  for (var entry in directory.listSync(recursive: true)) {
    if (!entry.path.endsWith(".dart")) continue;

    var relative = p.relative(entry.path, from: directory.path);
    processFile(entry, relative);
  }
}

/// Runs the formatter on [file].
void processFile(File file, [String label]) {
  if (label == null) label = file.path;

  var formatter = new DartFormatter(pageWidth: lineLength);
  try {
    var output = formatter.format(file.readAsStringSync());
    if (overwrite) {
      file.writeAsStringSync(output);
      print("Formatted $label");
    } else {
      print(output);
    }
  } on FormatterException catch (err) {
    stderr.writeln("Failed $label:\n$err");
  }
}
