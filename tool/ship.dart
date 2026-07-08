// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/src/tool_utils.dart';
import 'package:pub_semver/pub_semver.dart';

/// Runs the release process for dart_style.
///
/// 1. Runs `dart analyze` and ensures no errors or warnings.
/// 2. Runs `dart test` and ensures all tests pass.
/// 3. Updates the version in `pubspec.yaml` to remove the `-wip` suffix.
/// 4. Updates the version in `lib/src/cli/formatter_options.dart`.
/// 5. Ensures that the `CHANGELOG.md` has an entry for the new version.
Future<void> main() async {
  await _run('dart', ['analyze', '--fatal-warnings']);
  await _run('dart', [
    'test',
    '--reporter',
    'failures-only',
  ], 'Running tests...');

  var version = readPubspecVersion();

  // Remove "-wip" from the version if present.
  switch (version.preRelease) {
    case []:
      // Still update the version in case the formatter_options.dart is out of
      // sync with the pubspec.
      updateVersion(version);
      print('No change needed since version is already $version.');
    case ['wip']:
      version = Version(version.major, version.minor, version.patch);
      updateVersion(version);
      print('Updated version to $version.');
    default:
      print('Unexpected pre-release version $version. Don\'t ship!');
      exit(1);
  }

  // Check the CHANGELOG.
  var changelog = File('CHANGELOG.md').readAsLinesSync();
  if (!changelog.contains('## $version')) {
    print('Missing entry in CHANGELOG.md for $version. Don\'t ship!');
    exit(1);
  }

  print('        _    _');
  print('     __|_|__|_|__');
  print('   _|____________|__  Ready to ship!');
  print('  |o o o o o o o o /');
  print('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
}

/// Runs [executable] with [arguments].
///
/// Prints [message] before running. If the process fails, prints its output
/// and exits with the same exit code.
Future<void> _run(
  String executable,
  List<String> arguments, [
  String? message,
]) async {
  if (message != null) print(message);
  var process = await Process.start(executable, arguments);

  // Pipe output so the user can see progress.
  var stdoutFuture = stdout.addStream(process.stdout);
  var stderrFuture = stderr.addStream(process.stderr);

  var exitCode = await process.exitCode;
  await stdoutFuture;
  await stderrFuture;

  if (exitCode != 0) exit(exitCode);
  print('');
}
