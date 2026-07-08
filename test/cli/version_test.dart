// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/src/cli/formatter_options.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Makes sure that the version number printed by `dart format --version`
/// matches the actual version currently in the pubspec.
void main() {
  test('dartStyleVersion matches pubspec.yaml', () {
    var pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    var version = Version.parse(pubspec['version'] as String);

    // The version printed by `--version` strips off the `-wip` part.
    if (version.preRelease.join('.') == 'wip') {
      version = Version(version.major, version.minor, version.patch);
    }

    expect(dartStyleVersion, version.toString());
  });

  test('dartStyleVersion is not a pre-release or build version', () {
    var version = Version.parse(dartStyleVersion);
    expect(version.preRelease, isEmpty);
    expect(version.build, isEmpty);
  });
}
