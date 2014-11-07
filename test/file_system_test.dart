// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.file_system;

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:dart_style/src/file_util.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:scheduled_test/descriptor.dart' as d;
import 'package:scheduled_test/scheduled_test.dart';

void main() {
  setUp(() {
    var tempDir;
    schedule(() {
      return Directory.systemTemp.createTemp('dart_style.test.').then((dir) {
        tempDir = dir;
        d.defaultRoot = tempDir.path;
      });
    });

    currentSchedule.onComplete.schedule(() {
      d.defaultRoot = null;
      return tempDir.delete(recursive: true);
    });
  });

  test('validate code sample', () {
    var formatter = new DartFormatter();
    expect(formatter.format(_UNFORMATTED_CODE), _FORMATTED_CODE,
        reason: 'The sample code used in these tests should align with the '
          'formatter.');
  });

  test('Directories ending in ".dart" are valid', () {
    d.dir('code.dart', [
      d.file('a.dart', _UNFORMATTED_CODE),
    ]).create();

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot));
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('code.dart', [
      d.file('a.dart', _FORMATTED_CODE)
    ]).validate();
  });

  test("Don't format contents of sym links by default", () {
    d.dir('code', [
      d.file('a.dart', _UNFORMATTED_CODE),
    ]).create();

    d.file('target_file.dart', _UNFORMATTED_CODE).create();

    d.dir('target_dir', [
      d.file('b.dart', _UNFORMATTED_CODE),
    ]).create();

    schedule(() {
      // create a link to the target file in the code dir
      new Link(p.join(d.defaultRoot, 'code', 'linked_file.dart'))
          .createSync(p.join(d.defaultRoot, 'target_file.dart'));

      // create a link to the target dir in the code dir
      new Link(p.join(d.defaultRoot, 'code', 'linked_dir'))
          .createSync(p.join(d.defaultRoot, 'target_dir'));
    }, 'Create sym links.');

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, 'code'));
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('code', [
      d.file('a.dart', _FORMATTED_CODE),
      d.file('linked_file.dart', _UNFORMATTED_CODE),
      d.dir('linked_dir', [
        d.file('b.dart', _UNFORMATTED_CODE),
      ])
    ]).validate();
  });

  test("Format contents of sym links when 'followLinks: true'", () {
    d.dir('code', [
      d.file('a.dart', _UNFORMATTED_CODE),
    ]).create();

    d.file('target_file.dart', _UNFORMATTED_CODE).create();

    d.dir('target_dir', [
      d.file('b.dart', _UNFORMATTED_CODE),
    ]).create();

    schedule(() {
      // create a link to the target file in the code dir
      new Link(p.join(d.defaultRoot, 'code', 'linked_file.dart'))
          .createSync(p.join(d.defaultRoot, 'target_file.dart'));

      // create a link to the target dir in the code dir
      new Link(p.join(d.defaultRoot, 'code', 'linked_dir'))
          .createSync(p.join(d.defaultRoot, 'target_dir'));
    });

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, 'code'));
      processDirectory(dir, overwrite: true, followLinks: true);
    }, 'running formatter');

    d.dir('code', [
      d.file('a.dart', _FORMATTED_CODE),
      d.file('linked_file.dart', _FORMATTED_CODE),
      d.dir('linked_dir', [
        d.file('b.dart', _FORMATTED_CODE),
      ])
    ]).validate();
  });
}

const _UNFORMATTED_CODE = 'void  main()  =>  print("hello") ;';
const _FORMATTED_CODE = 'void main() => print("hello");\n';
