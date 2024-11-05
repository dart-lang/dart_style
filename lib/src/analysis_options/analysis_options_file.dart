// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'package:yaml/yaml.dart';

import 'file_system.dart';
import 'merge_options.dart';

/// The analysis options configuration is a dynamically-typed JSON-like data
/// structure.
///
/// (It's JSON-*like* and not JSON because maps in it may have non-string keys.)
typedef AnalysisOptions = Map<Object?, Object?>;

/// Interface for taking a "package:" URI that may appear in an analysis
/// options file's "include" key and resolving it to a file path which can be
/// passed to [FileSystem.join()].
typedef ResolvePackageUri = Future<String?> Function(Uri packageUri);

/// Reads an `analysis_options.yaml` file in [directory] or in the nearest
/// surrounding folder that contains that file using [fileSystem].
///
/// Stops walking parent directories as soon as it finds one that contains an
/// `analysis_options.yaml` file. If it reaches the root directory without
/// finding one, returns an empty [YamlMap].
///
/// If an `analysis_options.yaml` file is found, reads it and parses it to a
/// [YamlMap]. If the map contains an `include` key whose value is a list, then
/// reads any of the other referenced YAML files and merges them into this one.
/// Returns the resulting map with the `include` key removed.
///
/// If there any "package:" includes, then they are resolved to file paths
/// using [resolvePackageUri]. If [resolvePackageUri] is omitted, an exception
/// is thrown if any "package:" includes are found.
Future<AnalysisOptions> findAnalysisOptions(
    FileSystem fileSystem, FileSystemPath directory,
    {ResolvePackageUri? resolvePackageUri}) async {
  while (true) {
    var optionsPath = await fileSystem.join(directory, 'analysis_options.yaml');
    if (await fileSystem.fileExists(optionsPath)) {
      return readAnalysisOptions(fileSystem, optionsPath,
          resolvePackageUri: resolvePackageUri);
    }

    var parent = await fileSystem.parentDirectory(directory);
    if (parent == null) break;
    directory = parent;
  }

  // If we get here, we didn't find an analysis_options.yaml.
  return const {};
}

/// Uses [fileSystem] to read the analysis options file at [optionsPath].
///
/// If there any "package:" includes, then they are resolved to file paths
/// using [resolvePackageUri]. If [resolvePackageUri] is omitted, an exception
/// is thrown if any "package:" includes are found.
Future<AnalysisOptions> readAnalysisOptions(
    FileSystem fileSystem, FileSystemPath optionsPath,
    {ResolvePackageUri? resolvePackageUri}) async {
  var yaml = loadYamlNode(await fileSystem.readFile(optionsPath));

  // If for some reason the YAML isn't a map, consider it malformed and yield
  // a default empty map.
  if (yaml is! YamlMap) return const {};

  // Lower the YAML to a regular map.
  var options = {...yaml};

  Future<Map<Object?, Object?>> optionsFromInclude(String include) async {
    // If the include path is "package:", resolve it to a file path first.
    var includeUri = Uri.tryParse(include);
    if (includeUri != null && includeUri.scheme == 'package') {
      if (resolvePackageUri != null) {
        var filePath = await resolvePackageUri(includeUri);
        if (filePath != null) {
          include = filePath;
        } else {
          throw PackageResolutionException(
              'Failed to resolve package URI "$include" in include.');
        }
      } else {
        throw PackageResolutionException(
            'Couldn\'t resolve package URI "$include" in include because '
            'no package resolver was provided.');
      }
    }

    // The include path may be relative to the directory containing the current
    // options file.
    var includePath = await fileSystem.join(
        (await fileSystem.parentDirectory(optionsPath))!, include);
    return await readAnalysisOptions(fileSystem, includePath,
        resolvePackageUri: resolvePackageUri);
  }

  // If there is an `include:` key with a String value, then load that and merge
  // it with these options. If there is an `include:` key with a List value,
  // then load each value, merging successive included options, overriding
  // previous results with each set of included options, finally merging with
  // these options.
  switch (options['include']) {
    case String include:
      options.remove('include');
      var includeOptions = await optionsFromInclude(include);
      options = merge(includeOptions, options) as AnalysisOptions;
    case List<Object?> includeList:
      options.remove('include');
      var mergedIncludeOptions = AnalysisOptions();
      for (var include in includeList) {
        if (include is! String) {
          throw PackageResolutionException(
              'Unsupported "include" value in analysis options include list: '
              '"$include".');
        }
        var includeOptions = await optionsFromInclude(include);
        mergedIncludeOptions =
            merge(mergedIncludeOptions, includeOptions) as AnalysisOptions;
      }
      options = merge(mergedIncludeOptions, options) as AnalysisOptions;
    case null:
      break;
    case Object include:
      throw PackageResolutionException(
          'Unsupported "include" value in analysis options: "$include".');
  }

  return options;
}

/// Exception thrown when an analysis options file contains a "package:" URI in
/// an include and resolving the URI to a file path failed.
final class PackageResolutionException implements Exception {
  final String _message;

  PackageResolutionException(this._message);

  @override
  String toString() => _message;
}
