// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.utils;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:path/path.dart' as p;
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

const unformattedSource = 'void  main()  =>  print("hello") ;';
const formattedSource = 'void main() => print("hello");\n';

/// Runs the command line formatter, passing it [args].
Future<TestProcess> runFormatter([List<String> args]) {
  if (args == null) args = [];

  // Locate the "test" directory. Use mirrors so that this works with the test
  // package, which loads this suite into an isolate.
  var testDir = p.dirname(currentMirrorSystem()
      .findLibrary(#dart_style.test.utils)
      .uri
      .toFilePath());

  var formatterPath = p.normalize(p.join(testDir, "../bin/format.dart"));

  args.insert(0, formatterPath);

  // Use the same package root, if there is one.
  if (Platform.packageRoot != null && Platform.packageRoot.isNotEmpty) {
    args.insert(0, "--package-root=${Platform.packageRoot}");
  } else if (Platform.packageConfig != null &&
      Platform.packageConfig.isNotEmpty) {
    args.insert(0, "--packages=${Platform.packageConfig}");
  }

  return TestProcess.start(Platform.executable, args);
}

/// Runs the command line formatter, passing it the test directory followed by
/// [args].
Future<TestProcess> runFormatterOnDir([List<String> args]) {
  if (args == null) args = [];
  return runFormatter([d.sandbox]..addAll(args));
}
