// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:dart_style/src/dart_formatter.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import '../utils.dart';

void main() {
  compileFormatter();

  group('--trailing-commas', () {
    test('preserves commas if "preserve"', () async {
      await d.dir('foo', [d.file('main.dart', _unformatted)]).create();

      var process = await runFormatterOnDir(['--trailing-commas=preserve']);
      await process.shouldExit(0);

      await d.dir('foo', [d.file('main.dart', _formattedPreserve)]).validate();
    });

    test('automates commas if "automate"', () async {
      await d.dir('foo', [d.file('main.dart', _unformatted)]).create();

      var process = await runFormatterOnDir(['--trailing-commas=automate']);
      await process.shouldExit(0);

      await d.dir('foo', [d.file('main.dart', _formattedAutomate)]).validate();
    });

    test('error if any other value', () async {
      var process = await runFormatter(['--trailing-commas=wombat']);
      await process.shouldExit(64);
    });
  });

  test('ignore options file if trailing commas specified on the CLI', () async {
    await d.dir('foo', [
      analysisOptionsFile(trailingCommas: TrailingCommas.preserve),
      d.file('main.dart', _unformatted),
    ]).create();

    var process = await runFormatterOnDir(['--trailing-commas=automate']);
    await process.shouldExit(0);

    await d.dir('foo', [d.file('main.dart', _formattedAutomate)]).validate();
  });

  test('use mode from surrounding options', () async {
    await _testWithOptions({
      'formatter': {'trailing_commas': 'preserve'},
    }, preserve: true);
  });

  test('use default mode on invalid analysis options', () async {
    await _testWithOptions({'unrelated': 'stuff'}, preserve: false);
    await _testWithOptions({'formatter': 'not a map'}, preserve: false);
    await _testWithOptions({
      'formatter': {'no': 'trailing_commas'},
    }, preserve: false);
    await _testWithOptions({
      'formatter': {'trailing_commas': 'wombat'},
    }, preserve: false);
  });

  test('get mode from included options file', () async {
    await d.dir('foo', [
      analysisOptionsFile(include: 'other.yaml'),
      analysisOptionsFile(name: 'other.yaml', include: 'sub/third.yaml'),
      d.dir('sub', [
        analysisOptionsFile(
          name: 'third.yaml',
          trailingCommas: TrailingCommas.preserve,
        ),
      ]),
      d.file('main.dart', _unformatted),
    ]).create();

    var process = await runFormatterOnDir();
    await process.shouldExit(0);

    // Should preserve trailing commas.
    await d.dir('foo', [d.file('main.dart', _formattedPreserve)]).validate();
  });

  group('stdin', () {
    test('use mode from surrounding package', () async {
      await d.dir('foo', [
        analysisOptionsFile(trailingCommas: TrailingCommas.preserve),
      ]).create();

      var process = await runFormatter(['--stdin-name=foo/main.dart']);
      process.stdin.writeln(_unformatted);
      await process.stdin.close();

      // Preserves trailing commas.
      await expectLater(
        process.stdout,
        emitsInOrder(['var x = function(', '  argument,', ');']),
      );
      await process.shouldExit(0);
    });

    test('ignore options file if mode is specified', () async {
      await d.dir('foo', [
        analysisOptionsFile(trailingCommas: TrailingCommas.preserve),
        d.file('main.dart', _unformatted),
      ]).create();

      var process = await runFormatter([
        '--trailing-commas=preserve',
        '--stdin-name=foo/main.dart',
      ]);

      process.stdin.writeln(_unformatted);
      await process.stdin.close();

      // Preserves trailing commas.
      await expectLater(
        process.stdout,
        emitsInOrder(['var x = function(', '  argument,', ');']),
      );
      await process.shouldExit(0);
    });
  });
}

const _unformatted = '''
var x = function(argument,);
''';

const _formattedPreserve = '''
var x = function(
  argument,
);
''';

const _formattedAutomate = '''
var x = function(argument);
''';

/// Test that formatting a file with surrounding analysis_options.yaml
/// containing [options] formats the input with trailing commas preserved if
/// [preserve] is `true`.
Future<void> _testWithOptions(Object? options, {required bool preserve}) async {
  var expected = preserve ? _formattedPreserve : _formattedAutomate;

  await d.dir('foo', [
    d.FileDescriptor('analysis_options.yaml', jsonEncode(options)),
    d.file('main.dart', _unformatted),
  ]).create();

  var process = await runFormatterOnDir();
  await process.shouldExit(0);

  // Should format the file with the expected mode.
  await d.dir('foo', [d.file('main.dart', expected)]).validate();
}
