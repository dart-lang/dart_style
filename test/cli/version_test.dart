// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/src/cli/formatter_options.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Makes sure that the version number printed by `dart format --version`
/// matches the actual version currently in the pubspec.
void main() {
  test('dartStyleVersion matches pubspec.yaml', () {
    // Assume we're running this test from the root of the dart_style package.
    var pubspecPath = 'pubspec.yaml';

    // If it looks like we're running the test through the Dart SDK's test
    // runner, then the working directory will be the root of the Dart SDK, and
    // not the root of the dart_style package. In that case, we need to get a
    // path from the Dart SDK root to dart_style's own package root.
    var testPath = Platform.script.path;
    var dartStylePathInSdk = p.join('third_party', 'pkg', 'dart_style');
    if (testPath.contains(dartStylePathInSdk)) {
      pubspecPath = p.join(dartStylePathInSdk, pubspecPath);
    }

    var pubspec = loadYaml(File(pubspecPath).readAsStringSync()) as YamlMap;
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
