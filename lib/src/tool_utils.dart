// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Functionality shared by scripts in `tool/`.
library;

import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Reads the current package version from the pubspec.
Version readPubspecVersion() {
  var pubspecFile = File('pubspec.yaml');
  var pubspec = pubspecFile.readAsStringSync();
  return Version.parse((loadYaml(pubspec) as Map)['version'] as String);
}

/// Update the contents of [path] by replacing [pattern] with [replacement].
void updateFile(String path, RegExp pattern, String replacement) {
  var file = File(path);
  var source = file.readAsStringSync().replaceAll(pattern, replacement);
  file.writeAsStringSync(source);
}

/// Update the version numbers in the dart_style pubspec and command-line output
/// to [version].
void updateVersion(Version version) {
  // Update the version in the pubspec.
  updateFile(
    'pubspec.yaml',
    RegExp(r'^version: .*$', multiLine: true),
    'version: $version',
  );

  // Update the version constant in formatter_options.dart (minus any
  // pre-release prefix). We remove the `-wip` eagerly so that the version
  // number shown by `dart format --version` is the version that *will* be
  // published, even though we roll into the Dart SDK before publishing the
  // final version.
  var withoutPrerelease = Version(version.major, version.minor, version.patch);
  updateFile(
    'lib/src/cli/formatter_options.dart',
    RegExp(r"const dartStyleVersion = '[^']+';"),
    "const dartStyleVersion = '$withoutPrerelease';",
  );

  print("Updated version to '$version'.");
}
