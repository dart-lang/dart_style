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
// - '-v' for more logging verbosity.
void main(List<String> args) {
  try {
    var (
      int verbose,
      bool dryRun,
      File? experimentsFile,
      Version? targetVersion,
    ) = _parseArguments(
      args,
    );

    var stylePackageDir = _findStylePackageDir();
    if (verbose > 0) {
      stdout.writeln('dart_style root: ${stylePackageDir.path}');
    }
    if (verbose > 1) {
      stdout.writeln('Verbosity: $verbose');
    }
    if (verbose > 1 || (dryRun && verbose > 0)) {
      stdout.writeln('Dry-run: $dryRun');
    }

    if (experimentsFile == null) {
      experimentsFile = _findExperimentsFile();
      if (experimentsFile == null) {
        stderr
          ..writeln('Cannot find experiments file or SDK directory,')
          ..writeln('provide path to either on command line.')
          ..writeln(usage);
        exit(1);
      }
      if (verbose > 0) {
        stdout.writeln('Experiments file found: ${experimentsFile.path}');
      }
    } else if (verbose > 0) {
      stdout.writeln(
        'Experiments file from command line: ${experimentsFile.path}',
      );
    }
    var experiments = _parseExperiments(experimentsFile);
    var latestReleasedExperiment = experiments.values.fold<Version?>(
      null,
      Version.maxOrNull,
    );
    if (latestReleasedExperiment == null) {
      stderr.writeln('No released experiments in experiments file.');
      exit(1);
    }

    Updater(
      stylePackageDir,
      targetVersion ?? latestReleasedExperiment,
      experiments,
      verbose: verbose,
      dryRun: dryRun,
    ).run();
  } catch (e) {
    // Flush output before actually exiting.
    if (e case (:int exitCode)) {
      stdout.flush().then((_) {
        stderr.flush().then((_) {
          io.exit(exitCode);
        });
      });
    }
  }
}

(int verbose, bool dryRun, File? experimentsFile, Version? version)
_parseArguments(List<String> args) {
  // Parse argument list.
  var flagErrors = false;
  // General use of verbosity levels:
  // 0: No extra output.
  // 1+: Say what is done.
  // 2+: Also say when no change is made (what is *not* done).
  var verbose = 0;
  var dryRun = false;
  var printHelp = false;
  File? experimentsFile;
  Version? targetVersion;
  for (var arg in args) {
    if (arg.startsWith('-')) {
      for (var i = 1; i < arg.length; i++) {
        switch (arg[i]) {
          case 'n':
            dryRun = true;
          case 'v':
            verbose++;
          case 'h':
            printHelp = true;
          case var char:
            stderr.writeln('Invalid flag: "$char"');
            flagErrors = true;
        }
      }
    } else if (Version.tryParse(arg) case var version?) {
      if (targetVersion != null) {
        stderr.writeln(
          'More than one version argument: $targetVersion, $version',
        );
        flagErrors = true;
      }
      targetVersion = version;
    } else if (_checkExperimentsFileOrSdk(arg) case var file?) {
      if (experimentsFile != null) {
        stderr.writeln('More than one experiments or SDK argument: $arg');
        flagErrors = true;
      }
      experimentsFile = file;
    } else {
      stderr.writeln('Unrecognized argument: $arg');
      flagErrors = true;
    }
  }
  if (flagErrors) {
    stderr.writeln(usage);
    exit(1);
  }
  if (printHelp) {
    stdout.writeln(usage);
    exit(0);
  }
  return (verbose, dryRun, experimentsFile, targetVersion);
}

class Updater {
  final Directory root;
  final Version currentVersion;
  final int verbose;
  final bool dryRun;
  final Map<String, Version?> experiments;
  final FileEditor files;
  Updater(
    this.root,
    this.currentVersion,
    this.experiments, {
    this.verbose = 0,
    this.dryRun = false,
  }) : files = FileEditor(verbose: verbose - 1, dryRun: dryRun);

  void run() {
    var updatedPubspecVersion = _updatePubspec();
    _updateTests();
    files.flushChanges();
    if (updatedPubspecVersion && !dryRun) {
      stdout.writeln(
        'Updated PubSpec version. Run `dart pub get` and `dart format`.',
      );
    }
  }

  bool _updatePubspec() {
    var file = File(p.join(root.path, 'pubspec.yaml'));
    var versionRE = RegExp(
      r'(?<=^environment:\n  sdk: \^)([\w\-.+]+)(?=[ \t]*$)',
      multiLine: true,
    );
    var change = false;
    Version? unchangedVersion;
    files.edit(
      file,
      (pubspecText) => pubspecText.replaceFirstMapped(versionRE, (m) {
        var versionText = m[0]!;
        var existingVersion = Version.parse(versionText);
        if (existingVersion < currentVersion) {
          change = true;
          return '$currentVersion.0';
        }
        unchangedVersion = existingVersion;
        return versionText; // No change.
      }),
    );
    if (change) {
      if (verbose > 0) {
        stdout.writeln('Updated pubspec.yaml SDK to $currentVersion');
      }
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

  bool _updateTest(File testFile) => files.edit(testFile, (source) {
    if (!source.contains('(experiment ')) return null;
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
      return output.join('\n');
    }
    return null;
  });
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
// File system abstraction which caches changes to text files,
// so they can be written atomically at the end.

/// Cached edits of text files.
///
/// Use [edit] to edit a text file and return the new content.
/// Changes are cached and given to later edits of the same file.
///
/// Changed files can be flushed to disk using [flushChanges].
///
/// If [verbose] is positive, operations may print information
/// about what they do.
///
/// If [dryRun] is `true`, [flushChanges] does nothing, other than print
/// what it would have done.
class FileEditor {
  final int verbose;
  final bool dryRun;
  // Contains string if it has been changed.
  // Contains `null` if currently being edited.
  final Map<File, String?> _cache = {};

  FileEditor({this.verbose = 0, this.dryRun = false});

  /// Edit file with the given [path].
  ///
  /// Cannot edit a file while it's already being edited.
  ///
  /// The [editor] function is called with the content of the file,
  /// either read from the file system or cached already modified file content.
  /// The [editor] function should return the new content of the file.
  /// If it returns `null` or the same string, the file has not changed.
  ///
  /// Returns whether the file content changed.
  bool edit(File path, String? Function(String content) editor) {
    if (verbose > 0) {
      var fromString = ' from ${_cache.containsKey(path) ? 'cache' : 'disk'}';
      stdout.writeln('Loading ${path.path}$fromString.');
    }

    var existingContent = _cache[path];
    String content;
    if (existingContent != null) {
      content = existingContent;
    } else if (_cache.containsKey(path)) {
      throw ConcurrentModificationError(path);
    } else {
      content = path.readAsStringSync();
      _cache[path] = null;
    }
    var change = false;
    String? newContent;
    try {
      newContent = editor(content);
      change = newContent != null && newContent != content;
    } finally {
      // No change if function threw, or if it returned `null` or `content`.
      if (verbose > 0) {
        if (change) {
          var first = (existingContent == null) ? '' : ', first change to file';
          stdout.writeln('Saving changes to ${path.path}$first.');
        } else if (verbose > 1) {
          stdout.writeln('No changes to ${path.path}');
        }
      }
      if (change) {
        // Put text back after editing.
        _cache[path] = newContent;
      } else if (existingContent != null) {
        _cache[path] = existingContent;
      } else {
        _cache.remove(path); // No longer being edited.
      }
    }
    return change;
  }

  /// Saves all cached file changes to disk.
  ///
  /// Does nothing if dry-running.
  void flushChanges() {
    var count = 0;
    var prefix = dryRun ? 'Dry-run: ' : '';
    for (var file in [..._cache.keys]) {
      var content = _cache[file];
      if (content == null) {
        throw ConcurrentModificationError('Flushing cache while editing');
      }
      if (!dryRun) {
        file.writeAsStringSync(content);
        _cache.remove(file);
      }
      if (verbose > 1) {
        stdout.writeln('${prefix}Flushing updated ${file.path}');
      }
      count++;
    }
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
  // Check current directory. Script is run in the package root dir.
  var cwd = Directory.current;
  if (_isStylePackageDir(cwd)) return cwd;
  // Check parent directory of script file,
  // if run as `dart <pkgRoot>/tool/update_sdk.dart`.
  var scriptDir = p.dirname(p.absolute(p.fromUri(Platform.script)));
  var scriptParentDir = Directory(p.dirname(scriptDir));
  if (_isStylePackageDir(scriptParentDir)) return scriptParentDir;
  // Check ancestor directories of current directory,
  // if run from, fx, inside `<pkgRoot>/tool/`.
  var cursor = p.absolute(cwd.path);
  while (true) {
    var parentPath = p.dirname(cursor);
    if (cursor == parentPath) break;
    cursor = parentPath;
    var directory = Directory(cursor);
    if (_isStylePackageDir(directory)) return directory;
  }
  // Nothing worked.
  stderr.writeln("Couldn't find package root. Run from inside package.");
  exit(1);
}

bool _isStylePackageDir(Directory directory) {
  var pubspec = File(p.join(directory.path, 'pubspec.yaml'));
  // Could read less, but is unlikely to matter.
  return pubspec.existsSync() &&
      LineSplitter.split(pubspec.readAsStringSync()).first ==
          'name: dart_style';
}

// --------------------------------------------------------------------
// Find version and experiments file in SDK.

/// Used on command line arguments to see if they point to SDK or experiments.
File? _checkExperimentsFileOrSdk(String path) =>
    _tryExperimentsFile(path) ?? _tryExperimentsFileInSdkPath(path);

/// Used to find the experiments file if no command line path is given.
///
///
/// Tries to locate an SDK that has a `tools/experimental_features.yaml` file.
File? _findExperimentsFile() {
  var envSdk = Platform.environment['DART_SDK'];
  if (envSdk != null) {
    if (_tryExperimentsFileInSdkPath(envSdk) case var file?) {
      return file;
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
      if (_tryExperimentsFileInSdkDirectory(directory) case var file?) {
        return file;
      }
    }
  }
  return null;
}

File? _tryExperimentsFile(String path) {
  if (p.basename(path) == 'experimental_features.yaml') {
    var file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

File? _tryExperimentsFileInSdkPath(String path) {
  var directory = Directory(p.normalize(path));
  if (directory.existsSync()) {
    return _tryExperimentsFileInSdkDirectory(directory);
  }
  return null;
}

File? _tryExperimentsFileInSdkDirectory(Directory directory) {
  var experimentsFile = File(
    p.join(directory.path, 'tools', 'experimental_features.yaml'),
  );
  if (experimentsFile.existsSync()) return experimentsFile;
  return null;
}

class Version implements Comparable<Version> {
  final int major, minor;
  Version(this.major, this.minor);

  static Version? maxOrNull(Version? v1, Version? v2) {
    if (v1 == null) return v2;
    if (v2 == null) return v1;
    return max(v1, v2);
  }

  static Version max(Version v1, Version v2) => v1 >= v2 ? v1 : v2;

  static Version parse(String version) =>
      tryParse(version) ??
      (throw FormatException('Not a version string', version));

  static Version? tryParse(String version) {
    // Parse `###.###` optionally followed by `.<anything>`.
    var majorEnd = version.indexOf('.');
    if (majorEnd < 0) return null;
    var minorEnd = version.indexOf('.', majorEnd + 1);
    if (minorEnd < 0) minorEnd = version.length; // Accept semver prefix, `3.5`.
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

  // TODO: (https://dartbug.com/61891) - Remove ignores when issue is fixed.
  // ignore: unreachable_from_main
  bool operator <(Version other) =>
      major < other.major || major == other.major && minor < other.minor;
  // ignore: unreachable_from_main
  bool operator <=(Version other) =>
      major < other.major || major == other.major && minor <= other.minor;
  // ignore: unreachable_from_main
  bool operator >(Version other) => other < this;
  // ignore: unreachable_from_main
  bool operator >=(Version other) => other <= this;
}

/// Trailing `'s'` if number is not `1`.
String _plural(int number) => number == 1 ? '' : 's';

final String usage = '''
dart tool/update_sdk.dart [-h] [-v] [-n] [VERSION] [PATH]

Run from inside dart_style directory to be sure to be able to find it.
Uses path to `dart` executable to look for SDK directory.

VERSION  SemVer or 'major.minor' version.
         If provided, use that as SDK version in pubspec.yaml.
         If not provided, uses most recent feature release version.
PATH     Path to "experimental_features.yaml" or to an SDK repository containing
         that file in "tools".
         Will be searched for if not provided.

-v       Verbosity. Can be used multiple times.
-n       Dryrun. If set, does not write changed files back.
-h       Show usage.
''';

/// Caught by [main] to flush output before actually exiting.
Never exit(int value) {
  // ignore: only_throw_errors
  throw (exitCode: value);
}
