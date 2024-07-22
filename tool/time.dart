// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

void main(List<String> arguments) async {
  var startPattern = RegExp(r'>>> (\d+) (.*)');
  var endPattern = RegExp(r'<<< (\d+) (.*)');
  var instancePattern = RegExp(r'([^|]+)\|(.*)');

  var starts = <String, int>{};
  var cumulative = <String, int>{};
  var counts = <String, int>{};

  var lines = File('log.txt').readAsLinesSync();
  for (var line in lines) {
    if (startPattern.firstMatch(line) case var match?) {
      var time = int.parse(match[1]!);
      var label = match[2]!;
      starts[label] = time;
      // print('> $time: $label');
    } else if (endPattern.firstMatch(line) case var match?) {
      var time = int.parse(match[1]!);
      var label = match[2]!;

      var start = starts.remove(label);
      if (start == null) {
        print('No start for "$label"');
        throw '!';
      }
      var elapsed = time - start;

      var kind = label;
      if (instancePattern.firstMatch(label) case var match2?) {
        kind = match2[1]!.trim();
      }

      cumulative[kind] = (cumulative[kind] ?? 0) + elapsed;
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
  }

  var tracked = [
    // Nested:
    'format everything',
    'request and wait for format',
    'Worker._processFormatRequest()',
    // 'DartFormatter.formatSource()',
    // Sequential:
    // 'parse',
    // 'SourceVisitor visit AST',
    // 'SourceVisitor format',
  ];
  var trackedTimes = <String, double>{};

  var kinds = cumulative.keys.toList();
  kinds.sort();
  for (var kind in kinds) {
    var time = cumulative[kind]!;
    var total = (time / 1000).toStringAsFixed(3).padLeft(12);

    var line = '${kind.padRight(30)} $total ms';
    var count = counts[kind]!;
    if (count != 1) {
      var each = (time / count / 1000).toStringAsFixed(3);
      line += ', $count count ave $each';
    }
    print(line);

    if (tracked.contains(kind)) {
      trackedTimes[kind] = time / 1000;
    }
  }

  print(tracked.map((t) => '"$t"').join(','));
  var trackedTimesSorted = <double>[];
  for (var kind in tracked) {
    trackedTimesSorted.add(trackedTimes[kind]!);
  }
  print(trackedTimesSorted.map((t) => '"$t"').join(','));
}
