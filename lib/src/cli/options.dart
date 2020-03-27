// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:args/args.dart';

import '../style_fix.dart';

void defineOptions(ArgParser parser) {
  parser.addSeparator('Common options:');

  // Command implicitly adds "--help", so we only need to manually add it for
  // the old CLI.
  parser.addFlag('help',
      abbr: 'h', negatable: false, help: 'Shows this usage information.');

  parser.addFlag('overwrite',
      abbr: 'w',
      negatable: false,
      help: 'Overwrite input files with formatted output.');
  parser.addFlag('dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Show which files would be modified but make no changes.');

  parser.addSeparator('Non-whitespace fixes (off by default):');
  parser.addFlag('fix', negatable: false, help: 'Apply all style fixes.');

  for (var fix in StyleFix.all) {
    // TODO(rnystrom): Allow negating this if used in concert with "--fix"?
    parser.addFlag('fix-${fix.name}', negatable: false, help: fix.description);
  }

  parser.addSeparator('Other options:');

  parser.addOption('line-length',
      abbr: 'l', help: 'Wrap lines longer than this.', defaultsTo: '80');
  parser.addOption('indent',
      abbr: 'i', help: 'Spaces of leading indentation.', defaultsTo: '0');
  parser.addFlag('machine',
      abbr: 'm',
      negatable: false,
      help: 'Produce machine-readable JSON output.');
  parser.addFlag('set-exit-if-changed',
      negatable: false,
      help: 'Return exit code 1 if there are any formatting changes.');
  parser.addFlag('follow-links',
      negatable: false,
      help: 'Follow links to files and directories.\n'
          'If unset, links will be ignored.');
  parser.addFlag('version',
      negatable: false, help: 'Show version information.');

  parser.addSeparator('Options when formatting from stdin:');

  parser.addOption('preserve',
      help: 'Selection to preserve formatted as "start:length".');
  parser.addOption('stdin-name',
      help: 'The path name to show when an error occurs.',
      defaultsTo: '<stdin>');
  parser.addFlag('profile', negatable: false, hide: true);

  // Ancient no longer used flag.
  parser.addFlag('transform', abbr: 't', negatable: false, hide: true);
}

List<int> parseSelection(ArgResults argResults, String optionName) {
  var option = argResults[optionName];
  if (option == null) return null;

  // Can only preserve a selection when parsing from stdin.
  if (argResults.rest.isNotEmpty) {
    throw FormatException(
        'Can only use --$optionName when reading from stdin.');
  }

  try {
    var coordinates = option.split(':');
    if (coordinates.length != 2) {
      throw FormatException(
          'Selection should be a colon-separated pair of integers, "123:45".');
    }

    return coordinates.map<int>((coord) => int.parse(coord.trim())).toList();
  } on FormatException catch (_) {
    throw FormatException(
        '--$optionName must be a colon-separated pair of integers, was '
        '"${argResults[optionName]}".');
  }
}
