// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.command_line;

import 'package:scheduled_test/descriptor.dart' as d;
import 'package:scheduled_test/scheduled_test.dart';

import 'utils.dart';

void main() {
  setUpTestSuite();

  test("Exits with 0 on success.", () {
    d.dir("code", [
      d.file("a.dart", unformattedSource)
    ]).create();

    var process = runFormatter();
    process.shouldExit(0);
  });

  test("Exits with 64 on a command line argument error.", () {
    var process = runFormatter(["-wat"]);
    process.shouldExit(64);
  });

  test("Exits with 65 on a parse error.", () {
    d.dir("code", [
      d.file("a.dart", "herp derp i are a dart")
    ]).create();

    var process = runFormatter();
    process.shouldExit(65);
  });

  test("Errors if --dry-run and --overwrite are both passed.", () {
    d.dir("code", [
      d.file("a.dart", unformattedSource)
    ]).create();

    var process = runFormatter(["--dry-run", "--overwrite"]);
    process.shouldExit(64);
  });

  group("--dry-run", () {
    test("prints names of files that would change.", () {
      d.dir("code", [
        d.file("a_bad.dart", unformattedSource),
        d.file("b_good.dart", formattedSource),
        d.file("c_bad.dart", unformattedSource),
        d.file("d_good.dart", formattedSource)
      ]).create();

      var process = runFormatter(["--dry-run"]);
      process.stdout.expect("code/a_bad.dart");
      process.stdout.expect("code/c_bad.dart");
      process.shouldExit();
    });

    test("does not modify files.", () {
      d.dir("code", [
        d.file("a.dart", unformattedSource)
      ]).create();

      var process = runFormatter(["--dry-run"]);
      process.stdout.expect("code/a.dart");
      process.shouldExit();

      d.dir('code', [
        d.file('a.dart', unformattedSource)
    ]).validate();
    });
  });
}
