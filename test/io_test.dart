// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.io;

import 'dart:async';
import 'dart:io';

import 'package:dart_style/src/io.dart';
import 'package:path/path.dart' as p;
import 'package:scheduled_test/descriptor.dart' as d;
import 'package:scheduled_test/scheduled_test.dart';
import 'package:unittest/compact_vm_config.dart';

const _SOURCE = 'void  main()  =>  print("hello") ;';
const _FORMATTED = 'void main() => print("hello");\n';

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

  test('handles directory ending in ".dart"', () {
    d.dir('code.dart', [
      d.file('a.dart', _SOURCE),
    ]).create();

    schedule(() {
      var dir = new Directory(d.defaultRoot);
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('code.dart', [
      d.file('a.dart', _FORMATTED)
    ]).validate();
  });

  test("doesn't touch unchanged files", () {
    d.dir('code', [
      d.file('bad.dart', _SOURCE),
      d.file('good.dart', _FORMATTED),
    ]).create();

    modTime(String file) {
      return new File(p.join(d.defaultRoot, 'code', file)).statSync().modified;
    }

    var badBefore;
    var goodBefore;

    schedule(() {
      badBefore = modTime('bad.dart');
      goodBefore = modTime('good.dart');

      // Wait a bit so the mod time of a formatted file will be different.
      return new Future.delayed(new Duration(seconds: 1));
    });

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, 'code'));
      processDirectory(dir, overwrite: true);

      // Should be touched.
      var badAfter = modTime('bad.dart');
      expect(badAfter, isNot(equals(badBefore)));

      // Should not be touched.
      var goodAfter = modTime('good.dart');
      expect(goodAfter, equals(goodBefore));
    });
  });

  test("skips subdirectories whose name starts with '.'", () {
    d.dir('code', [
      d.dir('.skip', [
        d.file('a.dart', _SOURCE)
      ])
    ]).create();

    schedule(() {
      var dir = new Directory(d.defaultRoot);
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('code', [
      d.dir('.skip', [
        d.file('a.dart', _SOURCE)
      ])
    ]).validate();
  });

  test("traverses the given directory even if its name starts with '.'", () {
    d.dir('.code', [
      d.file('a.dart', _SOURCE)
    ]).create();

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, '.code'));
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('.code', [
      d.file('a.dart', _FORMATTED)
    ]).validate();
  });

  test("doesn't follow directory symlinks by default", () {
    d.dir('code', [
      d.file('a.dart', _SOURCE),
    ]).create();

    d.dir('target_dir', [
      d.file('b.dart', _SOURCE),
    ]).create();

    schedule(() {
      // Create a link to the target directory in the code directory.
      new Link(p.join(d.defaultRoot, 'code', 'linked_dir'))
          .createSync(p.join(d.defaultRoot, 'target_dir'));
    }, 'Create symlinks.');

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, 'code'));
      processDirectory(dir, overwrite: true);
    }, 'Run formatter.');

    d.dir('code', [
      d.file('a.dart', _FORMATTED),
      d.dir('linked_dir', [
        d.file('b.dart', _SOURCE),
      ])
    ]).validate();
  });

  test("follows directory symlinks when 'followLinks' is true", () {
    d.dir('code', [
      d.file('a.dart', _SOURCE),
    ]).create();

    d.dir('target_dir', [
      d.file('b.dart', _SOURCE),
    ]).create();

    schedule(() {
      // Create a link to the target directory in the code directory.
      new Link(p.join(d.defaultRoot, 'code', 'linked_dir'))
          .createSync(p.join(d.defaultRoot, 'target_dir'));
    });

    schedule(() {
      var dir = new Directory(p.join(d.defaultRoot, 'code'));
      processDirectory(dir, overwrite: true, followLinks: true);
    }, 'running formatter');

    d.dir('code', [
      d.file('a.dart', _FORMATTED),
      d.dir('linked_dir', [
        d.file('b.dart', _FORMATTED),
      ])
    ]).validate();
  });

  if (!Platform.isWindows) {
    test("doesn't follow file symlinks by default", () {
      d.dir('code').create();
      d.file('target_file.dart', _SOURCE).create();

      schedule(() {
        // Create a link to the target file in the code directory.
        new Link(p.join(d.defaultRoot, 'code', 'linked_file.dart'))
            .createSync(p.join(d.defaultRoot, 'target_file.dart'));
      }, 'Create symlinks.');

      schedule(() {
        var dir = new Directory(p.join(d.defaultRoot, 'code'));
        processDirectory(dir, overwrite: true);
      }, 'Run formatter.');

      d.dir('code', [
        d.file('linked_file.dart', _SOURCE),
      ]).validate();
    });

    test("follows file symlinks when 'followLinks' is true", () {
      d.dir('code').create();
      d.file('target_file.dart', _SOURCE).create();

      schedule(() {
        // Create a link to the target file in the code directory.
        new Link(p.join(d.defaultRoot, 'code', 'linked_file.dart'))
            .createSync(p.join(d.defaultRoot, 'target_file.dart'));
      });

      schedule(() {
        var dir = new Directory(p.join(d.defaultRoot, 'code'));
        processDirectory(dir, overwrite: true, followLinks: true);
      }, 'running formatter');

      d.dir('code', [
        d.file('linked_file.dart', _FORMATTED),
      ]).validate();
    });
  }
}
