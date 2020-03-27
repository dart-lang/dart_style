// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:dart_style/src/cli/format_command.dart';

/// A simple executable wrapper around the [Command] API defined by dart_style.
///
/// This enables tests to spawn this executable in order to verify the output
/// it prints.
void main(List<String> command) async {
  var runner =
      CommandRunner('dartfmt', 'Idiomatically formats Dart source code.');
  runner.addCommand(FormatCommand());

  try {
    await runner.runCommand(runner.parse(command));
  } on UsageException catch (exception) {
    stderr.writeln(exception);
    exit(64);
  }
}
