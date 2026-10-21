// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/formatter_options.dart' as analyzer;
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../source_code.dart';
import 'formatter_options.dart';

/// Manages an [AnalysisContextCollection] which is used to resolve package
/// configurations, infer the language version of files, and read
/// `analysis_options.yaml` files for formatter configuration.
class Analyzer {
  final AnalysisContextCollection _collection;

  /// Creates an analyzer for parsing and formatting [paths].
  Analyzer.forFiles(
    List<String> paths, {
    required Version? languageVersion,
    required List<String> experimentFlags,
  }) : this._(paths, languageVersion, experimentFlags);

  /// Creates an analyzer for parsing [stdin] input with a given [path] which
  /// is treated as if a synthetic file at [path] exists containing [stdin].
  factory Analyzer.forStdinPath({
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

  Analyzer._(
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

  /// Reads and parses the file at [path] then formats it with the given
  /// [options].
  ///
  /// Returns the resulting formatted output and `true` if the output is
  /// different from the original input.
  (SourceCode, {bool changed}) format(
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

    var formatter = DartFormatter(
      languageVersion:
          options.languageVersion ?? parsedResult.unit.languageVersion.package,
      indent: options.indent,
      pageWidth:
          options.pageWidth ??
          analysisOptions.formatterOptions.pageWidth ??
          DartFormatter.defaultPageWidth,
      trailingCommas:
          options.trailingCommas ??
          switch (analysisOptions.formatterOptions.trailingCommas) {
            null => TrailingCommas.automate,
            analyzer.TrailingCommas.automate => TrailingCommas.automate,
            analyzer.TrailingCommas.preserve => TrailingCommas.preserve,
          },
      // TODO(rnystrom): Should get any experiment flags enabled in
      // [analysisOptions] and pass them in here if [options.experimentFlags] is
      // empty. But it doesn't seem like the [AnalysisOptions] class exposes
      // the list of experiment flags directly, and the formatter doesn't
      // actually use them anyway, so don't bother trying to send them along.
      // (Only the parser uses experiment flags, and the
      // AnalysisContextCollection will send them to the parser.)
      experimentFlags: options.experimentFlags,
    );

    var output = formatUnitResult(
      formatter,
      parsedResult,
      selectionStart: selectionStart,
      selectionLength: selectionLength,
    );

    return (output, changed: parsedResult.content != output.text);
  }
}
