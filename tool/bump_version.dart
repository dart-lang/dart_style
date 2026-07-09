// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dart_style/src/tool_utils.dart';
import 'package:pub_semver/pub_semver.dart';

void main(List<String> args) {
  if (args.length != 1 ||
      !['major', 'minor', 'patch'].contains(args[0].toLowerCase())) {
    print('Usage: dart tool/bump_version.dart <major|minor|patch>');
    exit(64);
  }

  var component = args[0].toLowerCase();
  var version = readPubspecVersion();

  var nextVersion = switch (component) {
    'major' => Version(version.major + 1, 0, 0, pre: 'wip'),
    'minor' => Version(version.major, version.minor + 1, 0, pre: 'wip'),
    'patch' => Version(
      version.major,
      version.minor,
      version.patch + 1,
      pre: 'wip',
    ),
    _ => throw StateError('Unreachable.'),
  };

  updateVersion(nextVersion);
}
