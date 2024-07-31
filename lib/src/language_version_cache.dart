// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:pub_semver/pub_semver.dart';

import 'profile.dart';

/// Caches the default language version that should be used for files within
/// directories.
///
/// The default language version for a Dart file is found by walking the parent
/// directories of the file being formatted to look for a
/// `.dart_tool/package_config.json` file. When found, we cache the result for
/// the formatted file's parent directory. This way, when formatting multiple
/// files in the same directory, we don't have to look for and read the package
/// config multiple times, which is slow.
///
/// (When formatting dart_style on a Mac laptop, it would spend as much time
/// looking for package configs for each file as it did formatting if we don't
/// cache. Caching makes it ~10x faster to find the language version for each
/// file.)
class LanguageVersionCache {
  /// The previously cached default language version for all files immediately
  /// within a given directory.
  ///
  /// The version may be `null` if we formatted a file in that directory and
  /// discovered that there is no surrounding package.
  final Map<String, Version?> _directoryVersions = {};

  /// Looks for a package surrounding [file] and, if found, returns the default
  /// language version specified by that package.
  Future<Version?> find(File file) async {
    Profile.begin('look up package config');
    try {
      // Use the cached version (which may be `null`) if present.
      var directory = file.parent.path;
      if (_directoryVersions.containsKey(directory)) {
        return _directoryVersions[directory];
      }

      // Otherwise, walk the file system and look for it.
      var config = await findPackageConfig(file.parent);
      if (config?.packageOf(file.absolute.uri)?.languageVersion
          case var languageVersion?) {
        // Store the version as pub_semver's [Version] type because that's
        // what the analyzer parser uses, which is where the version
        // ultimately gets used.
        var version = Version(languageVersion.major, languageVersion.minor, 0);
        return _directoryVersions[directory] = version;
      }

      // We weren't able to resolve this file's directory, so don't try again.
      return _directoryVersions[directory] = null;
    } finally {
      Profile.end('look up package config');
    }
  }
}
