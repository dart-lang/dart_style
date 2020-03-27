// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_style/src/cli/formatter_options.dart';
import 'package:dart_style/src/cli/options.dart';
import 'package:dart_style/src/io.dart';
import 'package:dart_style/src/style_fix.dart';

void main(List<String> args) {
  var parser = ArgParser(allowTrailingOptions: true);

  defineOptions(parser);

  ArgResults argResults;
  try {
    argResults = parser.parse(args);
  } on FormatException catch (err) {
    usageError(parser, err.message);
  }

  if (argResults['help']) {
    printUsage(parser);
    return;
  }

  if (argResults['version']) {
    print(dartStyleVersion);
    return;
  }

  // Can only preserve a selection when parsing from stdin.
  List<int> selection;
  if (argResults['preserve'] != null && argResults.rest.isNotEmpty) {
    usageError(parser, 'Can only use --preserve when reading from stdin.');
  }

  try {
    selection = parseSelection(argResults, 'preserve');
  } on FormatException catch (_) {
    usageError(
        parser,
        '--preserve must be a colon-separated pair of integers, was '
        '"${argResults['preserve']}".');
  }

  if (argResults['dry-run'] && argResults['overwrite']) {
    usageError(
        parser, 'Cannot use --dry-run and --overwrite at the same time.');
  }

  void checkForReporterCollision(String chosen, String other) {
    if (!argResults[other]) return;

    usageError(parser, 'Cannot use --$chosen and --$other at the same time.');
  }

  var reporter = OutputReporter.print;
  if (argResults['dry-run']) {
    checkForReporterCollision('dry-run', 'overwrite');
    checkForReporterCollision('dry-run', 'machine');

    reporter = OutputReporter.dryRun;
  } else if (argResults['overwrite']) {
    checkForReporterCollision('overwrite', 'machine');

    if (argResults.rest.isEmpty) {
      usageError(parser,
          'Cannot use --overwrite without providing any paths to format.');
    }

    reporter = OutputReporter.overwrite;
  } else if (argResults['machine']) {
    reporter = OutputReporter.printJson;
  }

  if (argResults['profile']) {
    reporter = ProfileReporter(reporter);
  }

  if (argResults['set-exit-if-changed']) {
    reporter = SetExitReporter(reporter);
  }

  int pageWidth;
  try {
    pageWidth = int.parse(argResults['line-length']);
  } on FormatException catch (_) {
    usageError(
        parser,
        '--line-length must be an integer, was '
        '"${argResults['line-length']}".');
  }

  int indent;
  try {
    indent = int.parse(argResults['indent']);
    if (indent < 0 || indent.toInt() != indent) throw FormatException();
  } on FormatException catch (_) {
    usageError(
        parser,
        '--indent must be a non-negative integer, was '
        '"${argResults['indent']}".');
  }

  var followLinks = argResults['follow-links'];

  var fixes = <StyleFix>[];
  if (argResults['fix']) fixes.addAll(StyleFix.all);
  for (var fix in StyleFix.all) {
    if (argResults['fix-${fix.name}']) {
      if (argResults['fix']) {
        usageError(parser, '--fix-${fix.name} is redundant with --fix.');
      }

      fixes.add(fix);
    }
  }

  if (argResults.wasParsed('stdin-name') && argResults.rest.isNotEmpty) {
    usageError(parser, 'Cannot pass --stdin-name when not reading from stdin.');
  }

  var options = FormatterOptions(reporter,
      indent: indent,
      pageWidth: pageWidth,
      followLinks: followLinks,
      fixes: fixes);

  if (argResults.rest.isEmpty) {
    formatStdin(options, selection, argResults['stdin-name'] as String);
  } else {
    formatPaths(options, argResults.rest);
  }

  if (argResults['profile']) {
    (reporter as ProfileReporter).showProfile();
  }
}

/// Prints [error] and usage help then exits with exit code 64.
void usageError(ArgParser parser, String error) {
  printUsage(parser, error);
  exit(64);
}

void printUsage(ArgParser parser, [String error]) {
  var output = stdout;

  var message = 'Idiomatically formats Dart source code.';
  if (error != null) {
    message = error;
    output = stdout;
  }

  output.write('''$message

Usage:   dartfmt [options...] [files or directories...]

Example: dartfmt -w .
         Reformats every Dart file in the current directory tree.

${parser.usage}
''');
}
