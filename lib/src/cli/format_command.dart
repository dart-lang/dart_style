// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../io.dart';
import 'formatter_options.dart';
import 'output.dart';
import 'show.dart';
import 'summary.dart';

final class FormatCommand extends Command<int> {
  @override
  String get name => 'format';

  @override
  String get description => 'Idiomatically format Dart source code.';

  @override
  String get invocation =>
      '${runner!.executableName} $name [options...] <files or directories...>';

  FormatCommand({bool verbose = false}) {
    argParser.addFlag('verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show all options and flags with --help.');

    if (verbose) argParser.addSeparator('Output options:');

    argParser.addOption('output',
        abbr: 'o',
        help: 'Set where to write formatted output.',
        allowed: ['write', 'show', 'json', 'none'],
        allowedHelp: {
          'write': 'Overwrite formatted files on disk.',
          'show': 'Print code to terminal.',
          'json': 'Print code and selection as JSON.',
          'none': 'Discard output.'
        },
        defaultsTo: 'write');
    argParser.addOption('show',
        help: 'Set which filenames to print.',
        allowed: ['all', 'changed', 'none'],
        allowedHelp: {
          'all': 'All visited files and directories.',
          'changed': 'Only the names of files whose formatting is changed.',
          'none': 'No file names or directories.',
        },
        defaultsTo: 'changed',
        hide: !verbose);
    argParser.addOption('summary',
        help: 'Show the specified summary after formatting.',
        allowed: ['line', 'profile', 'none'],
        allowedHelp: {
          'line': 'Single-line summary.',
          'profile': 'How long it took for format each file.',
          'none': 'No summary.'
        },
        defaultsTo: 'line',
        hide: !verbose);

    argParser.addOption('language-version',
        help: 'Language version of formatted code.\n'
            'Use "latest" to parse as the latest supported version.\n'
            'Omit to look for a surrounding package config.',
        hide: !verbose);

    argParser.addFlag('set-exit-if-changed',
        negatable: false,
        help: 'Return exit code 1 if there are any formatting changes.');

    if (verbose) argParser.addSeparator('Other options:');

    argParser.addOption('page-width',
        help: 'Try to keep lines no longer than this.',
        defaultsTo: '80',
        hide: !verbose);
    // This is the old name for "--page-width". We keep it for backwards
    // compatibility but don't show it in the help output.
    argParser.addOption('line-length',
        abbr: 'l',
        help: 'Wrap lines longer than this.',
        defaultsTo: '80',
        hide: true);

    argParser.addOption('indent',
        abbr: 'i',
        help: 'Add this many spaces of leading indentation.',
        defaultsTo: '0',
        hide: !verbose);

    argParser.addFlag('follow-links',
        negatable: false,
        help: 'Follow links to files and directories.\n'
            'If unset, links will be ignored.',
        hide: !verbose);
    argParser.addFlag('version',
        negatable: false, help: 'Show dart_style version.', hide: !verbose);
    argParser.addMultiOption('enable-experiment',
        help: 'Enable one or more experimental features.\n'
            'See dart.dev/go/experiments.',
        hide: !verbose);

    if (verbose) argParser.addSeparator('Options when formatting from stdin:');

    argParser.addOption('selection',
        help: 'Track selection (given as "start:length") through formatting.',
        hide: !verbose);
    argParser.addOption('stdin-name',
        help:
            'The path that code read from stdin is treated as coming from.\n\n'
            'This path is used in error messages and also to locate a\n'
            'surrounding package to infer the code\'s language version.\n'
            'To avoid searching for a surrounding package config, pass\n'
            'in a language version using --language-version.',
        hide: !verbose);
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

    // Allow the old option name if the new one wasn't passed.
    String? pageWidthString;
    if (argResults.wasParsed('page-width')) {
      pageWidthString = argResults['page-width'] as String;
    } else if (argResults.wasParsed('line-length')) {
      pageWidthString = argResults['line-length'] as String;
    }

    int? pageWidth;
    if (pageWidthString != null) {
      pageWidth = int.tryParse(pageWidthString);
      if (pageWidth == null) {
        usageException(
            'Page width must be an integer, was "$pageWidthString".');
      } else if (pageWidth <= 0) {
        usageException('Page width must be a positive number, was $pageWidth.');
      }
    }

    var indent = int.tryParse(argResults['indent'] as String) ??
        usageException('--indent must be an integer, was '
            '"${argResults['indent']}".');

    if (indent < 0) {
      usageException('--indent must be non-negative, was '
          '"${argResults['indent']}".');
    }

    List<int>? selection;
    try {
      selection = _parseSelection(argResults, 'selection');
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
    var stdinName = argResults['stdin-name'] as String?;

    var options = FormatterOptions(
        languageVersion: languageVersion,
        indent: indent,
        pageWidth: pageWidth,
        followLinks: followLinks,
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

  List<int>? _parseSelection(ArgResults argResults, String optionName) {
    var option = argResults[optionName] as String?;
    if (option == null) return null;

    // Can only preserve a selection when parsing from stdin.
    if (argResults.rest.isNotEmpty) {
      throw FormatException(
          'Can only use --$optionName when reading from stdin.');
    }

    try {
      var coordinates = option.split(':');
      if (coordinates.length != 2) {
        throw const FormatException(
            'Selection should be a colon-separated pair of integers, '
            '"123:45".');
      }

      return coordinates.map<int>((coord) => int.parse(coord.trim())).toList();
    } on FormatException catch (_) {
      throw FormatException(
          '--$optionName must be a colon-separated pair of integers, was '
          '"${argResults[optionName]}".');
    }
  }
}
