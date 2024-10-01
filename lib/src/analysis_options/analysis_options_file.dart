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
Future<AnalysisOptions> findAnalysisOptions(
    FileSystem fileSystem, FileSystemPath directory) async {
  while (true) {
    var optionsPath = await fileSystem.join(directory, 'analysis_options.yaml');
    if (await fileSystem.fileExists(optionsPath)) {
      return readAnalysisOptions(fileSystem, optionsPath);
    }

    var parent = await fileSystem.parentDirectory(directory);
    if (parent == null) break;
    directory = parent;
  }

  // If we get here, we didn't find an analysis_options.yaml.
  return const {};
}

Future<AnalysisOptions> readAnalysisOptions(
    FileSystem fileSystem, FileSystemPath optionsPath) async {
  var yaml = loadYamlNode(await fileSystem.readFile(optionsPath));

  // Lower the YAML to a regular map.
  if (yaml is! YamlMap) return const {};
  var options = {...yaml};

  // If there is an `include:` key, then load that and merge it with these
  // options.
  if (options['include'] case String include) {
    options.remove('include');

    // The include path may be relative to the directory containing the current
    // options file.
    var includePath = await fileSystem.join(
        (await fileSystem.parentDirectory(optionsPath))!, include);
    var includeFile = await readAnalysisOptions(fileSystem, includePath);
    options = merge(includeFile, options) as AnalysisOptions;
  }

  return options;
}
