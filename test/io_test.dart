// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.io;

import 'dart:async';
import 'dart:io';

import 'package:dart_style/src/io.dart';
import 'package:path/path.dart' as p;
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test/test.dart';

import 'package:dart_style/src/formatter_options.dart';

import 'utils.dart';

void main() {
  var overwriteOptions = new FormatterOptions(OutputReporter.overwrite);

  var followOptions =
      new FormatterOptions(OutputReporter.overwrite, followLinks: true);

  test('handles directory ending in ".dart"', () async {
    await d.dir('code.dart', [
      d.file('a.dart', unformattedSource),
    ]).create();

    var dir = new Directory(d.sandbox);
    processDirectory(overwriteOptions, dir);

    await d.dir('code.dart', [
      d.file('a.dart', formattedSource),
    ]).validate();
  });

  test("doesn't touch unchanged files", () async {
    await d.dir('code', [
      d.file('bad.dart', unformattedSource),
      d.file('good.dart', formattedSource),
    ]).create();

    DateTime modTime(String file) =>
        new File(p.join(d.sandbox, 'code', file)).statSync().modified;

    var badBefore = modTime('bad.dart');
    var goodBefore = modTime('good.dart');

    // Wait a bit so the mod time of a formatted file will be different.
    await new Future.delayed(new Duration(seconds: 1));

    var dir = new Directory(p.join(d.sandbox, 'code'));
    processDirectory(overwriteOptions, dir);

    // Should be touched.
    var badAfter = modTime('bad.dart');
    expect(badAfter, isNot(equals(badBefore)));

    // Should not be touched.
    var goodAfter = modTime('good.dart');
    expect(goodAfter, equals(goodBefore));
  });

  test("skips subdirectories whose name starts with '.'", () async {
    await d.dir('code', [
      d.dir('.skip', [d.file('a.dart', unformattedSource)])
    ]).create();

    var dir = new Directory(d.sandbox);
    processDirectory(overwriteOptions, dir);

    await d.dir('code', [
      d.dir('.skip', [d.file('a.dart', unformattedSource)])
    ]).validate();
  });

  test("traverses the given directory even if its name starts with '.'",
      () async {
    await d.dir('.code', [d.file('a.dart', unformattedSource)]).create();

    var dir = new Directory(p.join(d.sandbox, '.code'));
    processDirectory(overwriteOptions, dir);

    await d.dir('.code', [d.file('a.dart', formattedSource)]).validate();
  });

  test("doesn't follow directory symlinks by default", () async {
    await d.dir('code', [
      d.file('a.dart', unformattedSource),
    ]).create();

    await d.dir('target_dir', [
      d.file('b.dart', unformattedSource),
    ]).create();

    // Create a link to the target directory in the code directory.
    new Link(p.join(d.sandbox, 'code', 'linked_dir'))
        .createSync(p.join(d.sandbox, 'target_dir'));

    var dir = new Directory(p.join(d.sandbox, 'code'));
    processDirectory(overwriteOptions, dir);

    await d.dir('code', [
      d.file('a.dart', formattedSource),
      d.dir('linked_dir', [
        d.file('b.dart', unformattedSource),
      ])
    ]).validate();
  });

  test("follows directory symlinks when 'followLinks' is true", () async {
    await d.dir('code', [
      d.file('a.dart', unformattedSource),
    ]).create();

    await d.dir('target_dir', [
      d.file('b.dart', unformattedSource),
    ]).create();

    // Create a link to the target directory in the code directory.
    new Link(p.join(d.sandbox, 'code', 'linked_dir'))
        .createSync(p.join(d.sandbox, 'target_dir'));

    var dir = new Directory(p.join(d.sandbox, 'code'));
    processDirectory(followOptions, dir);

    await d.dir('code', [
      d.file('a.dart', formattedSource),
      d.dir('linked_dir', [
        d.file('b.dart', formattedSource),
      ])
    ]).validate();
  });

  if (!Platform.isWindows) {
    // TODO(rnystrom): Figure out Windows equivalent of chmod and get this
    // test running on Windows too.
    test("reports error if file can not be written", () async {
      await d.file('a.dart', unformattedSource).create();

      Process.runSync("chmod", ["-w", p.join(d.sandbox, 'a.dart')]);

      var file = new File(p.join(d.sandbox, 'a.dart'));
      processFile(overwriteOptions, file);

      // Should not have been formatted.
      await d.file('a.dart', unformattedSource).validate();
    });

    test("doesn't follow file symlinks by default", () async {
      await d.dir('code').create();
      await d.file('target_file.dart', unformattedSource).create();

      // Create a link to the target file in the code directory.
      new Link(p.join(d.sandbox, 'code', 'linked_file.dart'))
          .createSync(p.join(d.sandbox, 'target_file.dart'));

      var dir = new Directory(p.join(d.sandbox, 'code'));
      processDirectory(overwriteOptions, dir);

      await d.dir('code', [
        d.file('linked_file.dart', unformattedSource),
      ]).validate();
    });

    test("follows file symlinks when 'followLinks' is true", () async {
      await d.dir('code').create();
      await d.file('target_file.dart', unformattedSource).create();

      // Create a link to the target file in the code directory.
      new Link(p.join(d.sandbox, 'code', 'linked_file.dart'))
          .createSync(p.join(d.sandbox, 'target_file.dart'));

      var dir = new Directory(p.join(d.sandbox, 'code'));
      processDirectory(followOptions, dir);

      await d.dir('code', [
        d.file('linked_file.dart', formattedSource),
      ]).validate();
    });
  }
}
