// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:pub_semver/pub_semver.dart';

/// Maintains the list of known supported Dart language versions.
class DartVersionHistory {
  /// The lowest language version supported by the formatter.
  static final Version earliest = all.first;

  /// The highest language version supported by the formatter.
  static final Version latest = all.last;

  /// The highest language version that uses the short formatting style.
  static final Version latestShortStyle = before(earliestTallStyle);

  /// The lowest language version that uses the tall formatting style.
  static final Version earliestTallStyle = Version(3, 7, 0);

  static const int _highest2xMinorVersion = 19;

  /// The minor version number of the highest 3.x language version supported by
  /// the formatter.
  ///
  /// This should be incremented when a new stable Dart SDK is released.
  static const int _highest3xMinorVersion = 13;

  /// All supported language versions.
  static List<Version> get all => _initialize();

  /// Returns the Dart language version that precedes [version].
  static Version before(Version version) {
    return switch (all.indexOf(version)) {
      -1 => throw ArgumentError('$version isn\'t a Dart language version.'),
      0 => throw ArgumentError('$version is the first supported version.'),
      var index => all[index - 1],
    };
  }

  /// Returns the Dart language version that follows [version] or `null` if
  /// [version] is the last supported version.
  static Version after(Version version) {
    return switch (all.indexOf(version)) {
      -1 => throw ArgumentError("$version isn't a Dart language version."),
      var index when index >= all.length - 1 => throw ArgumentError(
        '$version is the latest supported version.',
      ),
      var index => all[index + 1],
    };
  }

  static List<Version> _initialize() {
    // We don't track all Dart versions going back to the early days because
    // dart_style requires a Dart SDK whose support only goes back to 2.12.
    return [
      for (var i = 12; i <= _highest2xMinorVersion; i++) Version(2, i, 0),
      for (var i = 0; i <= _highest3xMinorVersion; i++) Version(3, i, 0),
    ];
  }
}

extension VersionExtension on Version {
  /// Converts this version to a `12.34` version string.
  String get majorMinor => '$major.$minor';
}
