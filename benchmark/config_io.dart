import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_style/src/cli/formatter_options.dart';
import 'package:dart_style/src/cli/output.dart';
import 'package:dart_style/src/cli/show.dart';
import 'package:dart_style/src/io.dart';
import 'package:dart_style/src/profile.dart';
import 'package:path/path.dart' as p;

/// Use a fixed seed to make the data deterministic.
final _random = Random(12345);

/// The stack of [_inDirectory()] calls that haven't completed yet.
final _directoryStack = <Directory>[];

/// Benchmarks the IO performed to read package configurations and
/// `analysis_options.yaml` files.
///
/// Generates a collection of synthetic packages that have package configs and
/// `analysis_options.yaml` files and then repeatedly formats them.
///
/// Does not measure the time to write the resulting formatted output back to
/// disk.
void main() async {
  var allPackages = [
    for (var adjective in _adjectives)
      for (var animal in _animals) '${adjective}_$animal',
  ];

  print('Creating synthetic packages...');
  var tempDir = await Directory.systemTemp.createTemp('dart_style_benchmark_');
  _directoryStack.add(tempDir);

  _inDirectory('lints', () {
    _buildFile('pubspec.yaml', (buffer) {
      buffer.writeln('name: lints');
    });

    _inDirectory('lib', () {
      _buildFile('analysis_options.yaml', (buffer) {
        buffer.writeln('formatter:');
        buffer.writeln('  page_width: 100');
      });
    });
  });

  try {
    for (var package in allPackages) {
      _inDirectory(package, () {
        _buildFile('pubspec.yaml', (buffer) {
          buffer.writeln('name: $package');
        });

        // Depend on 10-20 other packages so there is some content in the
        // package config.
        var otherPackages = allPackages
            .where((other) => other != package)
            .toList();
        otherPackages.shuffle(_random);
        var dependencies = [
          'lints',
          ...otherPackages.take(10 + _random.nextInt(11)),
        ];

        _buildFile('analysis_options.yaml', (buffer) {
          // Sometimes include another options file.
          if (_random.nextBool()) {
            buffer.writeln('include: package:lints/analysis_options.yaml');
          }
          buffer.writeln('formatter:');
          buffer.writeln('  page_width: ${50 + _random.nextInt(50)}');
        });

        _inDirectory('.dart_tool', () {
          _buildFile('package_config.json', (buffer) {
            var config = {
              'configVersion': 2,
              'packages': [
                {
                  'name': package,
                  'rootUri': '../',
                  'packageUri': 'lib/',
                  'languageVersion': '3.13',
                },
                for (var dependency in dependencies)
                  {
                    'name': dependency,
                    'rootUri': '../../$dependency',
                    'packageUri': 'lib/',
                    'languageVersion': '3.13',
                  },
              ],
            };

            buffer.writeln(const JsonEncoder.withIndent('  ').convert(config));
          });
        });

        _inDirectory('bin', () {
          for (var i = 0; i < 20; i++) {
            _buildFile('main_$i.dart', (buffer) {
              buffer.writeln('void main() {');
              buffer.write('  print(');
              _writeCallTree(buffer);
              buffer.writeln(');');
              buffer.writeln('}');
            });
          }
        });
      });
    }

    print('Warming up JIT...');
    var options = FormatterOptions(
      output: Output.none,
      show: Show.none,
      // Comment this out to use the current dart_style IO code:
      useAnalyzerApi: true,
    );
    for (var i = 0; i < 20; i++) {
      await formatPaths(options, [tempDir.path]);
    }

    Profile.reset();

    print('Running trials...');
    for (var i = 0; i < 20; i++) {
      Profile.begin('Benchmark trial');
      var stopwatch = Stopwatch()..start();
      await formatPaths(options, [tempDir.path]);
      print('Run #$i: ${stopwatch.elapsedMilliseconds}ms');
      Profile.end('Benchmark trial');
    }

    Profile.report();
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Creates a new directory at [path], relative to the current directory and
/// invokes [callback] with it as the current directory.
void _inDirectory(String path, void Function() callback) {
  var directory = Directory(p.join(_directoryStack.last.path, path));
  directory.createSync();
  _directoryStack.add(directory);
  callback();
  _directoryStack.removeLast();
}

/// Writes the StringBuffer populated by [builder] to [path] which is relative
/// to the surrounding directory from [_inDirectory()].
void _buildFile(String path, void Function(StringBuffer) builder) {
  var buffer = StringBuffer();
  builder(buffer);
  File(
    p.join(_directoryStack.last.path, path),
  ).writeAsStringSync(buffer.toString());
}

/// Writes a random nested function call to [buffer].
void _writeCallTree(StringBuffer buffer, [int depth = 0]) {
  buffer.write(_animals[_random.nextInt(_animals.length)]);
  if (depth < _random.nextInt(5) + 1) {
    buffer.write('(');
    var arguments = _random.nextInt(5);
    for (var i = 0; i < arguments; i++) {
      if (i > 0) buffer.write(',');
      _writeCallTree(buffer, depth + 1);
    }
    buffer.write(')');
  }
}

const _adjectives = [
  'cuddly',
  'fiesty',
  'grumpy',
  'happy',
  'hungry',
  'lazy',
  'noisy',
  'silly',
  'sleepy',
  'spunky',
];

const _animals = [
  'bat',
  'cat',
  'dog',
  'fox',
  'goat',
  'llama',
  'mouse',
  'owl',
  'pig',
  'wolf',
];
