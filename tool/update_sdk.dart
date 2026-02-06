// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Script to update the SDK dependency to the newest version,
/// and to remove references to experiments that have been released.
library;

import 'dart:convert' show LineSplitter;
import 'dart:io';
import 'dart:io' as io show exit;

import 'package:args/args.dart' as args;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart' as ver;
import 'package:yaml/yaml.dart' as y;

// Command line can contain:
//
// - Explicit version: `3.10`, which is used as version in pubspec.yaml.
// - Directory of SDK, may be relative to CWD.
// - `-n` for dry-run.
// - '-v' for more logging verbosity.
//   General use of verbosity levels:
//   0: No extra output.
//   1+: Say what is done.
//   2+: Also say when no change is made (what is *not* done).

void main(List<String> args) {
  try {
    var (
      int verbose,
      bool dryRun,
      File? experimentsFile,
      ver.Version? targetVersion,
    ) = _parseArguments(
      args,
    );
    verbose = 9;
    var stylePackageDir = _findStylePackageDir();
    if (verbose > 0) {
      stdout.writeln('dart_style root: ${stylePackageDir.path}');
    }
    if (verbose > 0) {
      stdout.writeln('Verbosity: $verbose');
    }
    if (verbose > 1 || (dryRun && verbose > 0)) {
      stdout.writeln('Dry-run: $dryRun');
    }
    if (verbose > 0 && targetVersion != null) {
      stdout.writeln(
        'Supplied target version: ${shortVersionText(targetVersion)}',
      );
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
    var (configVersion, experiments) = _parseExperiments(
      experimentsFile,
      targetVersion,
    );
    var latestReleasedExperiment = experiments.values.fold<ver.Version?>(
      null,
      maxVersionOrNull,
    );
    if (latestReleasedExperiment == null) {
      // Sanity check failed. We know there are released experiments.
      // (If we start removing no-longer-relevant experiments from the
      // experiments file, we should not remove experiments until significantly
      // after they have been released or dropped.)
      stderr.writeln('No released experiments in experiments file.');
      exit(1);
    }

    // Collect the configuration into an object to give all the methods
    // easy access to it.
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

(int verbose, bool dryRun, File? experimentsFile, ver.Version? version)
_parseArguments(List<String> arguments) {
  var argsParser = args.ArgParser()
    ..addFlag(
      'verbose',
      abbr: 'v',
      help: 'More verbose information during processing',
      negatable: false,
    )
    ..addFlag(
      'dryrun',
      abbr: 'n',
      negatable: false,
      help: 'Report changes, do not write them to disk',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Display usage information',
    );
  var parsedArgs = argsParser.parse(arguments);
  // TODO(https://github.com/dart-lang/core/issues/937):
  // Count multiple occurrences of `-v` if package:args supports it.
  var verbose = parsedArgs.flag('verbose') ? 1 : 0;
  var dryRun = parsedArgs.flag('dryrun');
  var printHelp = parsedArgs.flag('help');

  // Parse argument list.
  File? experimentsFile;
  ver.Version? targetVersion;
  var flagErrors = false;
  for (var arg in parsedArgs.rest) {
    if (arg.startsWith('-')) {
      stderr.writeln('Invalid flag: "$arg"');
      flagErrors = true;
    } else if (tryParseShortVersion(arg) case var version?) {
      if (targetVersion != null) {
        stderr.writeln(
          'More than one version argument: ${shortVersionText(targetVersion)},'
          ' $version',
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
    // Always print usage if there is an error.
    stderr.writeln(usage);
    stderr.writeln(argsParser.usage);
    exit(1);
  }
  if (printHelp) {
    // Only print usage if requested if no error.
    stdout.writeln(usage);
    stdout.writeln(argsParser.usage);
    exit(0);
  }
  return (verbose, dryRun, experimentsFile, targetVersion);
}

class Updater {
  // The `dart_style` package root.
  final Directory root;

  /// The target version that the `dart_style` package should use and support.
  ///
  /// Any experiment launched or discontinued before or in this version
  /// should not be used as experiment flags.
  final ver.Version currentVersion;

  // Verbosity level.
  final int verbose;

  // Whether to not save changes to disk.
  final bool dryRun;

  // Mapping from experiment name to the SDK version where they are launched
  // or discontinued.
  final Map<String, ver.Version?> experiments;

  // Modified file state.
  final FileEditor files;

  Updater(
    this.root,
    this.currentVersion,
    this.experiments, {
    this.verbose = 0,
    this.dryRun = false,
  }) : files = FileEditor(verbose: verbose - 1, dryRun: dryRun);

  /// Perform all updates to the `dart_style` package implied by [experiments].
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

  /// Updates the minium SDK constraint in `pubspec.yaml` to [currentVersion].
  ///
  /// If the existing version is greater than the requested version, no change
  /// is needed.
  ///
  /// Assumes a well-formatted `pubspec.yaml`, since it uses string manipulation
  /// to replace the version constraint.
  ///
  /// If the existing constraint is not before [currentVersion],
  /// it's left unchanged.
  bool _updatePubspec() {
    var file = File(p.join(root.path, 'pubspec.yaml'));
    var versionRE = RegExp(
      r'(?<=^environment:\n  sdk: \^)([\w\-.+]+)(?=[ \t]*$)',
      multiLine: true,
    );
    var change = false;
    ver.Version? unchangedVersion;
    String? unexpectedVersion;
    files.edit(
      file,
      (pubspecText) => pubspecText.replaceFirstMapped(versionRE, (m) {
        var versionText = m[0]!;
        ver.Version? existingVersion;
        try {
          existingVersion = ver.Version.parse(versionText);
        } on Object {
          // Not what we expected.
          unexpectedVersion = versionText;
        }
        if (existingVersion != null && existingVersion < currentVersion) {
          change = true;
          return ver.VersionConstraint.compatibleWith(
            currentVersion,
          ).toString();
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
    if (unexpectedVersion != null) {
      throw UnsupportedError(
        'SDK version constraint in pubspec.yaml: ^$unexpectedVersion',
      );
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
    ver.Version? globalVersion;
    // Set when an enabled experiment is removed from a single test.
    // Cleared when the next test starts.
    ver.Version? localVersion;
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
            var lineVersion = ver.Version.parse(m[0]!);
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
// Handle the experiments file.

/// Parses the `experimental_features.yaml` file.
///
/// Finds the current version, all experiments their 'enabled' version.
(ver.Version? currentVersion, Map<String, ver.Version?>) _parseExperiments(
  File experimentsFile,
  ver.Version? targetVersion,
) {
  var result = <String, ver.Version?>{};
  var yaml =
      y.loadYaml(
            experimentsFile.readAsStringSync(),
            sourceUrl: experimentsFile.uri,
          )
          as y.YamlMap;
  ver.Version? currentVersion;
  if (yaml['current-version'] case String versionText) {
    try {
      currentVersion = ver.Version.parse(versionText);
    } on Object {
      stderr.writeln('Unexpected current-version in experiments: $versionText');
    }
  }
  if (currentVersion != null &&
      targetVersion != null &&
      currentVersion < targetVersion) {
    throw UnsupportedError(
      'Target version higher than actual version:'
      ' $targetVersion > $currentVersion',
    );
  }
  var features = yaml['features'] as y.YamlMap;
  for (var MapEntry(key: name as String, value: info as y.YamlMap)
      in features.entries) {
    ver.Version? version;
    if (info['enabledIn'] case String enabledString) {
      version = ver.Version.parse(enabledString);
    }
    // If an experiment is expired without being enabled, which `macros`
    // will eventually be, it shouldn't be anywhere in tests.
    // It will not be removed.
    result[name] = version;
  }
  return (currentVersion, result);
}

// --------------------------------------------------------------------
// File system abstraction which caches changes to text files,
// so they can be written atomically at the end, or not if dry-running.

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
// Helper functions for figuring out where files are on disk.

/// Finds the root directory of the `dart_style` package.
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

// ------------------------------------------------------------------------
// Functions for finding the version and experiments files in an SDK repo.

/// Tries to find experiments file from command line path.
///
/// Accepts path to experiments file, and path to SDK itself.
File? _checkExperimentsFileOrSdk(String path) =>
    _tryExperimentsFile(path) ?? _tryExperimentsFileInSdkPath(path);

/// Tries to locate an SDK that has a `tools/experimental_features.yaml` file.
///
/// If `DART_SDK` environment variable is set, it tries using that.
/// Otherwise it tries to deduce a path from the [Platform.resolvedExecutable]
/// that is running this program. AOT-compiling this script may prevent that
/// detection. (Only believes it found a `dart` executable if it's named `dart`
/// or `dart.exe`.)
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

/// The experimental features file, if the path points to one.
///
/// Only accepted if the path points to an existing file named
/// `experimental_features.yaml`.
File? _tryExperimentsFile(String path) {
  if (p.basename(path) == 'experimental_features.yaml') {
    var file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

/// The experimental features file, if the [path] points to an SDK repo root.
File? _tryExperimentsFileInSdkPath(String path) {
  var directory = Directory(p.normalize(path));
  if (directory.existsSync()) {
    return _tryExperimentsFileInSdkDirectory(directory);
  }
  return null;
}

/// The experimental features file, if [directory] exists and is an SDK root.
///
/// The directory is  considered an SDK root if there is an
/// `tools/experimental_features.yaml` file in the directory.
File? _tryExperimentsFileInSdkDirectory(Directory directory) {
  var experimentsFile = File(
    p.join(directory.path, 'tools', 'experimental_features.yaml'),
  );
  if (experimentsFile.existsSync()) return experimentsFile;
  return null;
}

/// Tries to parse as "short" (major-minor only) version as a [ver.Version].
///
/// Accepts for example `"3.8"` where the [ver.Version.parse] function
/// requires a patch version to be valid, like `"3.8.0"`.
ver.Version? tryParseShortVersion(String source) {
  // Must have format: \d+\.\d+
  var dot = source.indexOf('.');
  if (dot < 0) return null;
  var major = int.tryParse(source.substring(0, dot));
  if (major == null) return null;
  var minor = int.tryParse(source.substring(dot + 1));
  if (minor == null) return null;
  return ver.Version(major, minor, 0);
}

String shortVersionText(ver.Version version) =>
    '${version.major}.${version.minor}';

/// Max of two nullable versions, where a `null` value is less than non-`null`.
ver.Version? maxVersionOrNull(ver.Version? v1, ver.Version? v2) {
  if (v1 == null) return v2;
  if (v2 == null) return v1;
  return v1 < v2 ? v2 : v1;
}

/// Trailing `'s'` if number is not `1`.
String _plural(int number) => number == 1 ? '' : 's';

final String usage = '''
dart tool/update_sdk.dart [-h] [-v] [-n] [VERSION] [PATH]

Run from inside dart_style directory to be sure to be able to find it.
Uses path to `dart` executable to look for SDK directory if not provided.

VERSION  SemVer or 'major.minor' version.
         If provided, use that as SDK version in pubspec.yaml.
         If not provided, uses most recent feature release version.
PATH     Path to "experimental_features.yaml" or to an SDK repository containing
         that file in "tools/".
         Will be searched for if not provided.
''';

/// Caught by [main] to flush output before actually exiting.
Never exit(int value) {
  // ignore: only_throw_errors
  throw (exitCode: value);
}
