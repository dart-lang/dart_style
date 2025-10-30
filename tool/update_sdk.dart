// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Script to update the SDK dependency to the newest version,
/// and to remove references to experiments that have been released.
library;

import 'dart:convert' show LineSplitter;
import 'dart:io';
import 'dart:io' as io show exit;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart' as y;

// Command line can contain:
//
// - Explicit version: `3.10`, which is used as version in pubspec.yaml.
// - Directory of SDK, may be relative to CWD.
// - `-n` for dry-run.
void main(List<String> args) {
  try {
    var flagErrors = false;
    // General use of verbosity levels:
    // 0: No extra output.
    // 1+: Say what is done
    // 2+: Also say when no change is made.
    var verbose = 0;
    var dryRun = false;
    var nonFlagArgs = <String>[];
    for (var arg in args) {
      if (arg.startsWith('-')) {
        for (var i = 1; i < arg.length; i++) {
          switch (arg[i]) {
            case 'n':
              dryRun = true;
            case 'v':
              verbose++;
            case var char:
              stderr.writeln('Invalid flag: "$char"');
              flagErrors = true;
          }
        }
      } else {
        nonFlagArgs.add(arg);
      }
    }
    if (flagErrors) {
      stderr.writeln(usage);
      exit(1);
    }
    if (verbose > 1) {
      stdout.writeln('Verbosity: $verbose');
    }
    if (verbose > 0) {
      if (dryRun || verbose > 1) stdout.writeln('Dry-run: $dryRun');
    }

    var stylePackageDir = _findStylePackageDir();
    if (verbose > 0) {
      stdout.writeln('dart_style root: ${stylePackageDir.path}');
    }
    if (findExperimentsFile(nonFlagArgs) case var experimentsFile?) {
      // A version number on the command line will be "current version",
      // otherwise use the maximal version of released experiments in the
      // experiments file.
      Version? version;
      var experiments = _parseExperiments(experimentsFile);
      for (var arg in nonFlagArgs) {
        if (Version.tryParse(arg) case var explicitVersion?) {
          version = explicitVersion;
          if (verbose > 0) {
            stdout.writeln('SDK version from command line: $version');
          }
          break;
        }
      }
      if (version == null) {
        version = experiments.values.nonNulls.reduce(Version.max);
        if (verbose > 0) {
          stdout.writeln('SDK version from experiments: $version');
        }
      }

      Updater(
        stylePackageDir,
        version,
        experiments,
        verbose: verbose,
        dryRun: dryRun,
      ).run();
    } else {
      stderr.writeln('Cannot find experiments file.');
      stderr.writeln(usage);
      exit(1);
    }
  } catch (e) {
    if (e case (:int exitCode)) {
      stdout.flush().then((_) {
        stderr.flush().then((_) {
          io.exit(exitCode);
        });
      });
    }
  }
}

class Updater {
  final Directory root;
  final Version currentVersion;
  final int verbose;
  final Map<String, Version?> experiments;
  final FileCache files;
  Updater(
    this.root,
    this.currentVersion,
    this.experiments, {
    this.verbose = 0,
    bool dryRun = false,
  }) : files = FileCache(verbose: verbose, dryRun: dryRun);
  void run() {
    _updatePubspec();
    _updateTests();
    files.flushSaves();
  }

  bool _updatePubspec() {
    var file = File(p.join(root.path, 'pubspec.yaml'));
    var pubspecText = files.load(file);
    var versionRE = RegExp(
      r'(?<=^environment:\n  sdk: \^)([\w\-.+]+)(?=[ \t]*$)',
      multiLine: true,
    );
    var change = false;
    Version? unchangedVersion;
    pubspecText = pubspecText.replaceFirstMapped(versionRE, (m) {
      var versionText = m[0]!;
      var existingVersion = Version.parse(versionText);
      if (existingVersion < currentVersion) {
        change = true;
        return '$currentVersion.0';
      }
      unchangedVersion = existingVersion;
      return versionText; // No change.
    });
    if (change) {
      if (verbose > 0) {
        stdout.writeln('Updated pubspec.yaml SDK to $currentVersion');
      }
      files.save(file, pubspecText);
      return true;
    }
    if (unchangedVersion == null) {
      throw UnsupportedError('Cannot find SDK version in pubspec.yaml');
    }
    if (verbose > 1) {
      stdout.writeln('Pubspec SDK version unchanged: $unchangedVersion');
    }
    return false;
  }

  void _updateTests() {
    var testDirectory = Directory(p.join(root.path, 'test'));
    for (var file in testDirectory.listSync(recursive: true)) {
      if (file is File && file.path.endsWith('.stmt')) {
        if (_updateTest(file) && verbose > 0) {
          stdout.writeln('Updated test: ${file.path}');
        }
      }
    }
  }

  // Matches an `(experiment exp-name)` entry, plus a single prior space.
  // Captures:
  // - name: The exp-name
  static final _experimentRE = RegExp(r' ?\(experiment (?<name>[\w\-]+)\)');
  
  /// Matches a language version on a format test output line.
  static final _languageVersionRE = RegExp(r'(?<=^<<< )\d+\.\d+\b');

  bool _updateTest(File testFile) {
    var source = files.load(testFile);
    if (!source.contains('(experiment ')) return false;
    // Experiments can be written in two places:
    // - at top, after first line, as a lone of `(experiment exp-name)`
    //   in which case it applies to every test.
    // - on individual test as `>>> (experiment exp-name) Test name`
    //   where it only applies to that test.
    //
    // Language version can occur after first part of source
    // - `<<< 3.8 optional description`

    var output = <String>[];
    // Set when an enabled experiment is removed from the header,
    // and the feature requires this version.
    // Is the *minimum language version* allowed for tests in the file.
    Version? globalVersion;
    // Set when an enabled experiment is removed from a single test.
    // Cleared when the next test starts.
    Version? localVersion;
    var inHeader = true;
    var change = false;
    for (var line in LineSplitter.split(source)) {
      if (line.startsWith('>>>')) {
        inHeader = false;
        localVersion = null;
      }
      if (line.startsWith('<<<')) {
        if (_languageVersionRE.firstMatch(line) case var m?) {
          var minVersion = localVersion ?? globalVersion;
          if (minVersion != null) {
            var lineVersion = Version.parse(m[0]!);
            if (lineVersion < minVersion) {
              change = true;
              line = line.replaceRange(m.start, m.end, minVersion.toString());
            }
          }
        } else {
          // If we have a minimum version imposed by a removed experiment,
          // put it on any output that doesn't have a version.
          var minVersion = localVersion ?? globalVersion;
          if (minVersion != null) {
            line = line.replaceRange(3, 3, ' $minVersion');
            change = true;
          }
        }
      } else if (line.isNotEmpty) {
        line = line.replaceAllMapped(_experimentRE, (m) {
          m as RegExpMatch;
          var experimentName = m.namedGroup('name')!;
          var release = experiments[experimentName];
          if (release == null || release > currentVersion) {
            // Not released yet.
            if (!experiments.containsKey(experimentName)) {
              stderr.writeln(
                'Unrecognized experiment name "$experimentName"'
                ' in ${testFile.path}',
              );
            }
            return m[0]!; // Keep experiment.
          }
          // Remove the experiment entry, the experiment is released.
          // Ensure language level, if specified, is high enough to enable
          // the feature without a flag.
          var currentMinVersion = localVersion ?? globalVersion;
          if (currentMinVersion == null || release > currentMinVersion) {
            if (inHeader) {
              globalVersion = release;
            } else {
              localVersion = release;
            }
          }
          change = true;
          return '';
        });
        // Top-level experiment lines only,
        if (line.isEmpty) continue;
      }
      output.add(line);
    }
    if (change) {
      if (output.isNotEmpty && output.last.isNotEmpty) {
        output.add(''); // Make sure to have final newline.
      }
      files.save(testFile, output.join('\n'));
      return true;
    }
    return false;
  }
}

// --------------------------------------------------------------------
// Parse the `experimental_features.yaml` file to find experiments
// and their 'enabled' version.
Map<String, Version?> _parseExperiments(File experimentsFile) {
  var result = <String, Version?>{};
  var yaml =
      y.loadYaml(
            experimentsFile.readAsStringSync(),
            sourceUrl: experimentsFile.uri,
          )
          as y.YamlMap;
  var features = yaml['features'] as y.YamlMap;
  for (var MapEntry(key: name as String, value: info as y.YamlMap)
      in features.entries) {
    Version? version;
    if (info['enabledIn'] case String enabledString) {
      version = Version.tryParse(enabledString);
    }
    result[name] = version;
  }
  return result;
}

// --------------------------------------------------------------------
// File system abstraction which caches changes, so they can be written
// atomically at the end.

class FileCache {
  final int verbose;
  final bool dryRun;
  final Map<File, ({String content, bool changed})> _cache = {};

  FileCache({this.verbose = 0, this.dryRun = false});

  String load(File path) {
    if (verbose > 0) {
      var fromString =
          verbose > 1
              ? ' from ${_cache.containsKey(path) ? 'cache' : 'disk'}'
              : '';
      stdout.writeln('Reading ${path.path}$fromString.');
    }

    return (_cache[path] ??= (content: path.readAsStringSync(), changed: false))
        .content;
  }

  void save(File path, String content) {
    var existing = _cache[path];
    if (verbose == 1) stdout.writeln('Saving ${path.path}.');
    if (existing != null) {
      if (existing.content == content) {
        if (verbose > 2) stdout.writeln('Saving ${path.path} with no changes');
        return;
      }
      if (verbose > 2) stdout.writeln('Save updates ${path.path}');
    } else if (verbose > 2) {
      stdout.writeln('Save ${path.path}, not in cache');
    }
    _cache[path] = (content: content, changed: true);
  }

  void flushSaves() {
    var count = 0;
    var prefix = dryRun ? 'Dry-run: ' : '';
    _cache.updateAll((file, value) {
      if (!value.changed) return value;
      var content = value.content;
      if (!dryRun) file.writeAsStringSync(content);
      if (verbose > 1) {
        stdout.writeln('${prefix}Flushing updated ${file.path}');
      }
      count++;
      return (content: content, changed: false);
    });
    if (verbose > 0) {
      if (count > 0) {
        stdout.writeln(
          '${prefix}Flushed $count changed file${_plural(count)}.',
        );
      } else if (verbose > 1) {
        stdout.writeln('${prefix}Flushing file cache with no changed files.');
      }
    }
  }
}

// --------------------------------------------------------------------
// Find the root directory of the `dart_style` package.

Directory _findStylePackageDir() {
  var cwd = Directory.current;
  if (_isStylePackageDir(cwd)) return cwd;
  var scriptDir = p.dirname(p.absolute(p.fromUri(Platform.script)));
  var scriptParentDir = Directory(p.dirname(scriptDir));
  if (_isStylePackageDir(scriptParentDir)) return scriptParentDir;
  var cursor = p.absolute(cwd.path);
  while (true) {
    var parentPath = p.dirname(cursor);
    if (cursor == parentPath) break;
    cursor = parentPath;
    var directory = Directory(cursor);
    if (_isStylePackageDir(directory)) return directory;
  }
  throw UnsupportedError(
    "Couldn't find package root. Run from inside package.",
  );
}

bool _isStylePackageDir(Directory directory) {
  var pubspec = File(p.join(directory.path, 'pubspec.yaml'));
  return pubspec.existsSync() &&
      LineSplitter.split(pubspec.readAsStringSync()).first ==
          'name: dart_style';
}

// --------------------------------------------------------------------
// Find version and experiments file in SDK.

File? findExperimentsFile(List<String> args) {
  // Check if argument is SDK directory.
  if (args.isNotEmpty) {
    for (var arg in args) {
      var directory = Directory(p.absolute(arg));
      if (directory.existsSync()) {
        if (_experimentsInSdkDirectory(directory) case var file?) {
          return file;
        }
      }
    }
  }
  // Try relative to `dart` executable.
  var cursor = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(cursor) == 'dart') {
    while (true) {
      var parent = p.dirname(cursor);
      if (parent == cursor) break;
      cursor = parent;
      var directory = Directory(cursor);
      if (_experimentsInSdkDirectory(directory) case var file?) {
        return file;
      }
    }
  }
  return null;
}

File? _experimentsInSdkDirectory(Directory directory) {
  var experimentsFile = File(
    p.join(directory.path, 'tools', 'experimental_features.yaml'),
  );
  if (experimentsFile.existsSync()) return experimentsFile;
  return null;
}

class Version implements Comparable<Version> {
  final int major, minor;
  Version(this.major, this.minor);

  static Version max(Version v1, Version v2) => v1.compareTo(v2) >= 0 ? v1 : v2;

  static Version min(Version v1, Version v2) => v1.compareTo(v2) <= 0 ? v1 : v2;

  static Version parse(String version) =>
      tryParse(version) ??
      (throw FormatException('Not a version string', version));

  static Version? tryParse(String version) {
    var majorEnd = version.indexOf('.');
    if (majorEnd < 0) return null;
    var minorEnd = version.indexOf('.', majorEnd + 1);
    if (minorEnd < 0) minorEnd = version.length; // Accept `3.5`.
    var major = int.tryParse(version.substring(0, majorEnd));
    if (major == null) return null;
    var minor = int.tryParse(version.substring(majorEnd + 1, minorEnd));
    if (minor == null) return null;
    return Version(major, minor);
  }

  @override
  int compareTo(Version other) {
    var delta = major.compareTo(other.major);
    if (delta == 0) delta = minor.compareTo(other.minor);
    return delta;
  }

  @override
  int get hashCode => Object.hash(major, minor);
  @override
  bool operator ==(Object other) =>
      other is Version && major == other.major && minor == other.minor;
  @override
  String toString() => '$major.$minor';

  bool operator <(Version other) =>
      major < other.major || major == other.major && minor < other.minor;
  bool operator <=(Version other) =>
      major < other.major || major == other.major && minor <= other.minor;
  bool operator >(Version other) => other < this;
  bool operator >=(Version other) => other <= this;
}

/// Trailing `'s'` if number is not `1`.
String _plural(int number) => number == 1 ? '' : 's';

final String usage = '''
dart tool/update_sdk.dart [-v] [-n] [VERSION] [SDKDIR]

Run from inside dart_style directory to be sure to be able to find it.
Uses path to `dart` executable to look for SDK directory.

VERSION  SemVer or `major.minor` version.
         If provided, use that as SDK version in pubspec.yaml.
SDKDIR   Path to SDK repository containing experimental_features.yaml file.
         Will be searched for if not provided.

-v       Verbosity. Can be used multiple times.
-n       Dryrun. If set, does not write changed files back. 
''';

void exit(int value) {
  // ignore: only_throw_errors
  throw (exitCode: value);
}
