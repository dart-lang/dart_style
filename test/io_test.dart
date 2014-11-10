// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.file_system;

import 'dart:io';

import 'package:dart_style/src/io.dart';
import 'package:path/path.dart' as p;
import 'package:scheduled_test/descriptor.dart' as d;
import 'package:scheduled_test/scheduled_test.dart';
import 'package:unittest/compact_vm_config.dart';

void main() {
  // Tidy up the unittest output.
  filterStacks = true;
  formatStacks = true;
  useCompactVMConfiguration();

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

  if (!Platform.isWindows) {
    test("doesn't follow symlinks by default", () {
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
      }, 'Create symlinks.');

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

    test("format contents of symlinks when 'followLinks: true'", () {
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
}

const _UNFORMATTED_CODE = 'void  main()  =>  print("hello") ;';
const _FORMATTED_CODE = 'void main() => print("hello");\n';
