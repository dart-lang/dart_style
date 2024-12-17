// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: unreachable_from_main

import 'package:grinder/grinder.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart' as yaml;

/// Matches the version line in dart_style's pubspec.
final _versionPattern = RegExp(r'^version: .*$', multiLine: true);

void main(List<String> args) => grind(args);

@DefaultTask()
@Task()
Future<void> validate() async {
  // Test it.
  await TestRunner().testAsync();

  // Make sure it's warning clean.
  Analyzer.analyze('bin/format.dart', fatalWarnings: true);

  // Format it.
  Dart.run('bin/format.dart', arguments: ['.']);
}

/// Increments the patch version of the current version.
@Task()
Future<void> patch() async {
  var version = _readVersion();
  _updateVersion(
      Version(version.major, version.minor, version.patch + 1, pre: 'wip'));
}

/// Increments the minor version of the current version.
@Task()
Future<void> minor() async {
  var version = _readVersion();
  _updateVersion(Version(version.major, version.minor + 1, 0, pre: 'wip'));
}

/// Increments the major version of the current version.
@Task()
Future<void> major() async {
  var version = _readVersion();
  _updateVersion(Version(version.major + 1, 0, 0, pre: 'wip'));
}

/// Gets ready to publish a new version of the package.
///
/// To publish a version, you need to:
///
/// 1.  Make sure the version in the pubspec is a "-wip" number. This should
///     already be the case since you've already landed patches that change
///     the formatter and bumped to that as a consequence.
///
/// 2.  Run this task:
///
///     ```
///     dart run grinder bump
///     ```
///
/// 3.  Commit the change to a branch, push it to GitHub, and review and merge
///     it there.
///
/// 4.  After the PR is merged using the publishing automation to publish the
///     new version:
///
///     https://github.com/dart-lang/ecosystem/wiki/Publishing-automation
@Task()
@Depends(validate)
Future<void> ship() async {
  var version = _readVersion();

  // Require a "-wip" version since we don't otherwise know what to bump it to.
  if (!version.isPreRelease) {
    throw StateError('Cannot publish non-wip version $version.');
  }

  // Don't allow versions like "1.2.3-dev+4" because it's not clear if the
  // user intended the "+4" to be discarded or not.
  if (version.build.isNotEmpty) {
    throw StateError('Cannot publish build version $version.');
  }

  // Remove the pre-release suffix.
  _updateVersion(Version(version.major, version.minor, version.patch));
}

/// Reads the current package version from the pubspec.
Version _readVersion() {
  var pubspecFile = getFile('pubspec.yaml');
  var pubspec = pubspecFile.readAsStringSync();
  return Version.parse((yaml.loadYaml(pubspec) as Map)['version'] as String);
}

/// Sets version numbers in the dart_style repository with [version].
void _updateVersion(Version version) {
  // Read the version from the pubspec.
  var pubspecFile = getFile('pubspec.yaml');
  var pubspec = pubspecFile.readAsStringSync();

  // Update the version in the pubspec.
  pubspec = pubspec.replaceAll(_versionPattern, 'version: $version');
  pubspecFile.writeAsStringSync(pubspec);

  // Update the version constant in formatter_options.dart (minus any
  // pre-release prefix). We do this eagerly so that the version number shown
  // by `dart format --version` is the version that *will* be published, even
  // though we roll into the Dart SDK before publishing the final version.
  var withoutPrerelease = Version(version.major, version.minor, version.patch);
  var versionFile = getFile('lib/src/cli/formatter_options.dart');
  var versionSource = versionFile.readAsStringSync().replaceAll(
      RegExp(r"const dartStyleVersion = '[^']+';"),
      "const dartStyleVersion = '$withoutPrerelease';");
  versionFile.writeAsStringSync(versionSource);

  log("Updated version to '$version'.");
}
