// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:grinder/grinder.dart';
import 'package:yaml/yaml.dart' as yaml;

main(args) => grind(args);

@DefaultTask()
@Task()
validate() async {
  await new TestRunner().testAsync();
  Analyzer.analyze("bin/format.dart", fatalWarnings: true);
  DartFmt.format(".");
}

/// Gets ready to publish a new version of the package.
///
/// To publish a version, you need to:
///
///   1. Bump the version in the pubspec to a non-dev number.
///
///   2. Run this task:
///
///         pub run grinder bump
///
///   3. Commit the change to a branch.
///
///   4. Send it out for review:
///
///         git cl upload
///
///   5. After the review is complete, land it:
///
///         git cl land
///
///   6. Tag the commit:
///
///         git tag -a "<version>" -m "<version>"
///         git push origin <version>
///
///   7. Publish the package:
///
///         pub lish
@Task()
@Depends(validate)
bump() async {
  // Read the version from the pubspec.
  var pubspec = yaml.loadYaml(getFile("pubspec.yaml").readAsStringSync());
  var version = pubspec["version"];
  print(version);

  if (version.contains("-dev")) throw "Cannot publish a dev version.";

  // Update the version constant in bin/format.dart.
  var binFormatFile = getFile("bin/format.dart");
  var binFormat = binFormatFile.readAsStringSync().replaceAll(
      new RegExp(r'const version = "[^"]+";'), 'const version = "$version";');
  binFormatFile.writeAsStringSync(binFormat);
  print("Updated version constant to '$version'.");
}
