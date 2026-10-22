// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/analysis_options.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:pub_semver/pub_semver.dart';

import 'formatter_options.dart';

/// Manages an [AnalysisContextCollection] which is used to resolve package
/// configurations, infer the language version of files, and read
/// `analysis_options.yaml` files for formatter configuration.
class Analyzer {
  final AnalysisContextCollection _collection;

  /// Creates an analyzer for parsing and formatting [paths].
  new forFiles(
    List<String> paths, {
    required Version? languageVersion,
    required List<String> experimentFlags,
  }) : this._(paths, languageVersion, experimentFlags);

  /// Creates an analyzer for parsing [stdin] input with a given [path] which
  /// is treated as if a synthetic file at [path] exists containing [stdin].
  factory forStdinPath({
    required String stdin,
    required String path,
    required Version? languageVersion,
    required List<String> experimentFlags,
  }) {
    // Create a virtual file for the contents of stdin at the given path.
    var provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    provider.setOverlay(path, content: stdin, modificationStamp: 0);

    return Analyzer._([path], languageVersion, experimentFlags, provider);
  }

  new _(
    List<String> paths,
    Version? languageVersion,
    List<String> experimentFlags, [
    ResourceProvider? resourceProvider,
  ]) : _collection = AnalysisContextCollection(
         includedPaths: paths,
         resourceProvider: resourceProvider,
         languageVersionOverride: languageVersion,
         enabledExperiments: experimentFlags,
       );

  /// Releases all IO resources used by the [AnalysisContextCollection].
  Future<void> dispose() => _collection.dispose();

  /// Reads and parses the file at [path].
  ///
  /// Returns the parsed contents of the file and the [AnalysisOptions] that
  /// should be applied to it.
  (ParsedUnitResult, AnalysisOptions) read(
    FormatterOptions options,
    String path, {
    int? selectionStart,
    int? selectionLength,
  }) {
    var context = _collection.contextFor(path);
    var analysisOptions = context.getAnalysisOptionsForFile(
      context.contextRoot.resourceProvider.getFile(path),
    );

    var parsedResult =
        context.currentSession.getParsedUnit(path) as ParsedUnitResult;

    return (parsedResult, analysisOptions);
  }
}
