// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../io.dart';
import '../short/style_fix.dart';
import 'formatter_options.dart';
import 'options.dart';
import 'output.dart';
import 'show.dart';
import 'summary.dart';

class FormatCommand extends Command<int> {
  @override
  String get name => 'format';

  @override
  String get description => 'Idiomatically format Dart source code.';

  @override
  String get invocation =>
      '${runner!.executableName} $name [options...] <files or directories...>';

  FormatCommand({bool verbose = false}) {
    defineOptions(argParser, oldCli: false, verbose: verbose);
  }

  @override
  Future<int> run() async {
    var argResults = this.argResults!;

    if (argResults['version'] as bool) {
      print(dartStyleVersion);
      return 0;
    }

    var show = const {
      'all': Show.all,
      'changed': Show.changed,
      'none': Show.none
    }[argResults['show']]!;

    var output = const {
      'write': Output.write,
      'show': Output.show,
      'none': Output.none,
      'json': Output.json,
    }[argResults['output']]!;

    var summary = Summary.none;
    switch (argResults['summary'] as String) {
      case 'line':
        summary = Summary.line();
        break;
      case 'profile':
        summary = Summary.profile();
        break;
    }

    // If the user is sending code through stdin, default the output to stdout.
    if (!argResults.wasParsed('output') && argResults.rest.isEmpty) {
      output = Output.show;
    }

    // If the user wants to print the code and didn't indicate how the files
    // should be printed, default to only showing the code.
    if (!argResults.wasParsed('show') &&
        (output == Output.show || output == Output.json)) {
      show = Show.none;
    }

    // If the user wants JSON output, default to no summary.
    if (!argResults.wasParsed('summary') && output == Output.json) {
      summary = Summary.none;
    }

    // Can't use --verbose with anything but --help.
    if (argResults['verbose'] as bool && !(argResults['help'] as bool)) {
      usageException('Can only use --verbose with --help.');
    }

    // Can't use any summary with JSON output.
    if (output == Output.json && summary != Summary.none) {
      usageException('Cannot print a summary with JSON output.');
    }

    Version? languageVersion;
    if (argResults['language-version'] case String version) {
      var versionPattern = RegExp(r'^([0-9]+)\.([0-9]+)$');
      if (version == 'latest') {
        languageVersion = DartFormatter.latestLanguageVersion;
      } else if (versionPattern.firstMatch(version) case var match?) {
        languageVersion =
            Version(int.parse(match[1]!), int.parse(match[2]!), 0);
      } else {
        usageException('--language-version must be a version like "3.2" or '
            '"latest", was "$version".');
      }
    }

    var pageWidth = int.tryParse(argResults['line-length'] as String) ??
        usageException('--line-length must be an integer, was '
            '"${argResults['line-length']}".');

    var indent = int.tryParse(argResults['indent'] as String) ??
        usageException('--indent must be an integer, was '
            '"${argResults['indent']}".');

    if (indent < 0) {
      usageException('--indent must be non-negative, was '
          '"${argResults['indent']}".');
    }

    var fixes = <StyleFix>[];
    if (argResults['fix'] as bool) fixes.addAll(StyleFix.all);
    for (var fix in StyleFix.all) {
      if (argResults['fix-${fix.name}'] as bool) {
        if (argResults['fix'] as bool) {
          usageException('--fix-${fix.name} is redundant with --fix.');
        }

        fixes.add(fix);
      }
    }

    List<int>? selection;
    try {
      selection = parseSelection(argResults, 'selection');
    } on FormatException catch (exception) {
      usageException(exception.message);
    }

    var followLinks = argResults['follow-links'] as bool;
    var setExitIfChanged = argResults['set-exit-if-changed'] as bool;

    var experimentFlags = argResults['enable-experiment'] as List<String>;

    // If stdin isn't connected to a pipe, then the user is not passing
    // anything to stdin, so let them know they made a mistake.
    if (argResults.rest.isEmpty && stdin.hasTerminal) {
      usageException('Missing paths to code to format.');
    }

    if (argResults.rest.isEmpty && output == Output.write) {
      usageException('Cannot use --output=write when reading from stdin.');
    }

    if (argResults.wasParsed('stdin-name') && argResults.rest.isNotEmpty) {
      usageException('Cannot pass --stdin-name when not reading from stdin.');
    }
    var stdinName = argResults['stdin-name'] as String;

    var options = FormatterOptions(
        languageVersion: languageVersion,
        indent: indent,
        pageWidth: pageWidth,
        followLinks: followLinks,
        fixes: fixes,
        show: show,
        output: output,
        summary: summary,
        setExitIfChanged: setExitIfChanged,
        experimentFlags: experimentFlags);

    if (argResults.rest.isEmpty) {
      await formatStdin(options, selection, stdinName);
    } else {
      await formatPaths(options, argResults.rest);
      options.summary.show();
    }

    // Return the exitCode explicitly for tools which embed dart_style
    // and set their own exitCode.
    return exitCode;
  }
}
