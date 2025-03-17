// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:pub_semver/pub_semver.dart';

import 'analysis_options/analysis_options_file.dart';
import 'analysis_options/io_file_system.dart';
import 'dart_formatter.dart';
import 'profile.dart';

/// Caches the nearest surrounding package config file for files in directories.
///
/// The formatter reads `.dart_tool/package_config.json` files in order to
/// determine the default language version of files in that package and to
/// resolve "package:" URIs in "analysis_options.yaml" files.
///
/// Walking the file system to find the package config and then reading it off
/// disk is very slow. We know that every formatted file in the same directory
/// will share the same package config, so this caches a previously read
/// config for each directory.
///
/// (When formatting dart_style on a Mac laptop, it would spend as much time
/// looking for package configs for each file as it did formatting if we don't
/// cache. Caching makes it ~10x faster to find the config for each file.)
///
/// This class also directly caches the language versions and page widths that
/// are then inferred from the package config and analysis_options.yaml files.
final class ConfigCache {
  /// The previously cached package config for all files immediately within a
  /// given directory.
  final Map<String, PackageConfig?> _directoryConfigs = {};

  /// The previously cached default language version for all files immediately
  /// within a given directory.
  ///
  /// The version may be `null` if we formatted a file in that directory and
  /// discovered that there is no surrounding package.
  final Map<String, Version?> _directoryVersions = {};

  /// The previously cached configured options for all files immediately within
  /// a given directory.
  final Map<String, _FormatterOptions> _directoryOptions = {};

  final IOFileSystem _fileSystem = IOFileSystem();

  /// Looks for a package surrounding [file] and, if found, returns the default
  /// language version specified by that package.
  Future<Version?> findLanguageVersion(File file, String displayPath) async {
    // Use the cached version (which may be `null`) if present.
    var directory = file.parent.path;
    if (_directoryVersions.containsKey(directory)) {
      return _directoryVersions[directory];
    }

    // Otherwise, walk the file system and look for it.
    var config = await _findPackageConfig(
      file,
      displayPath,
      forLanguageVersion: true,
    );

    if (config?.packageOf(file.absolute.uri)?.languageVersion
        case var languageVersion?) {
      // Store the version as pub_semver's [Version] type because that's
      // what the analyzer parser uses, which is where the version
      // ultimately gets used.
      var version = Version(languageVersion.major, languageVersion.minor, 0);
      return _directoryVersions[directory] = version;
    }

    // We weren't able to resolve this file's version, so don't try again.
    return _directoryVersions[directory] = null;
  }

  /// Looks for an "analysis_options.yaml" file surrounding [file] and, if
  /// found and valid, returns the page width specified by that config file.
  ///
  /// Otherwise returns `null`.
  ///
  /// The schema looks like:
  ///
  ///     formatter:
  ///       page_width: 123
  Future<int?> findPageWidth(File file) async {
    return (await _findFormatterOptions(file)).pageWidth;
  }

  /// Looks for an "analysis_options.yaml" file surrounding [file] and, if
  /// found and valid, returns the trailing comma handling specified by that
  /// config file.
  ///
  /// Otherwise returns `null`.
  ///
  /// The schema looks like:
  ///
  ///     formatter:
  ///       trailing_commas: preserve # Or "automate".
  Future<TrailingCommas?> findTrailingCommas(File file) async {
    return (await _findFormatterOptions(file)).trailingCommas;
  }

  /// Looks for an "analysis_options.yaml" file surrounding [file] and, if
  /// found and valid, returns the configured options.
  ///
  /// If no options file could be found or it doesn't contain a "formatter" key
  /// whose value is a map, returns a default set of options where all settings
  /// are `null`.
  Future<_FormatterOptions> _findFormatterOptions(File file) async {
    // Use the cached version if present.
    var directory = file.parent.path;
    if (_directoryOptions[directory] case var options?) return options;

    int? pageWidth;
    TrailingCommas? trailingCommas;

    try {
      // Look for a surrounding "analysis_options.yaml" file.
      var optionsFile = await findAnalysisOptions(
        _fileSystem,
        await _fileSystem.makePath(file.path),
        resolvePackageUri: (uri) => _resolvePackageUri(file, uri),
      );

      if (optionsFile['formatter'] case Map<Object?, Object?> formatter) {
        if (formatter case {'page_width': int width}) {
          pageWidth = width;
        }

        if (formatter case {'trailing_commas': var commas}) {
          switch (commas) {
            case 'automate':
              trailingCommas = TrailingCommas.automate;
            case 'preserve':
              trailingCommas = TrailingCommas.preserve;
            default:
              stderr.writeln(
                'Warning: "trailing_commas" option should be "automate" or '
                '"preserve", but was "$commas".',
              );
          }
        }
      }
    } on PackageResolutionException catch (exception) {
      // Report the error, but use the default settings and keep going.
      stderr.writeln(
        'Warning: Package resolution error when reading '
        '"analysis_options.yaml" file:\n$exception',
      );
    }

    // Cache whichever options we found (or `null` if we didn't find them).
    return _directoryOptions[directory] = _FormatterOptions(
      pageWidth,
      trailingCommas,
    );
  }

  /// Look for and cache the nearest package surrounding [file].
  Future<PackageConfig?> _findPackageConfig(
    File file,
    String displayPath, {
    required bool forLanguageVersion,
  }) async {
    Profile.begin('look up package config');
    try {
      // Use the cached one (which might be `null`) if we have it.
      var directory = file.parent.path;
      if (_directoryConfigs.containsKey(directory)) {
        return _directoryConfigs[directory];
      }

      // Otherwise, walk the file system and look for it. If we fail to find it,
      // store `null` so that we don't look again in that same directory.
      return _directoryConfigs[directory] = await findPackageConfig(
        file.parent,
      );
    } catch (error) {
      // We need a language version, so report an error if we can't find one.
      // We don't need a page width because we happily use the default, so say
      // nothing in that case.
      if (forLanguageVersion) {
        stderr.writeln(
          'Could not read package configuration for '
          '$displayPath:\n$error',
        );
        stderr.writeln(
          'To avoid searching for a package configuration, '
          'specify a language version using "--language-version".',
        );
      }
      return null;
    } finally {
      Profile.end('look up package config');
    }
  }

  /// Resolves a "package:" [packageUri] using the nearest package config file
  /// surrounding [file].
  ///
  /// If there is no package config file around [file], or the package config
  /// doesn't contain the package for [packageUri], returns `null`. Otherwise,
  /// returns an absolute file path for where [packageUri] can be found on disk.
  Future<String?> _resolvePackageUri(File file, Uri packageUri) async {
    var config = await _findPackageConfig(
      file,
      file.path,
      forLanguageVersion: false,
    );
    if (config == null) return null;

    return config.resolve(packageUri)?.toFilePath();
  }
}

/// The formatter options that can be configured in the "analysis_options.yaml"
/// file.
final class _FormatterOptions {
  /// The configured page width, or `null` if there is no options file or the
  /// options file doesn't specify it.
  final int? pageWidth;

  /// The configured comma handling, or `null` if there is no options file or
  /// the options file doesn't specify it.
  final TrailingCommas? trailingCommas;

  _FormatterOptions(this.pageWidth, this.trailingCommas);
}
