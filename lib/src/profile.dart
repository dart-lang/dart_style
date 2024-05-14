// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:developer';
import 'dart:math';

/// Manually instrumented profiling.
///
/// Using a general-purpose sampling profiler is difficult with the formatter
/// because so much of its code is recursive. Manual instrumentation can provide
/// more concise, meaningful data.
class Profile {
  /// Whether profiling is enabled.
  ///
  /// Enabling profiling has a noticeable effect on overall performance. When
  /// measuring, make sure to have profiling enabled when gathering baseline
  /// measurements so that the comparison to the optimized version takes into
  /// account the profiling overhead.
  ///
  /// When this is `false`, hopefully the compiler is able to completely
  /// tree-shake calls to these methods. This should always be `false` in the
  /// committed version of this file.
  static const enabled = false;

  /// Tracks counts of labelled occurrences.
  static final Map<String, int> _counts = {};

  /// The total accumulated time from completed calls to [begin()]/[end()] for
  /// each label, in microseconds.
  static final Map<String, int> _accumulatedTimes = {};

  /// Label and start time (in microseconds) of each call to [begin()] that has
  /// not had a corresponding call to [end()] yet.
  static final List<(String, int)> _running = [];

  /// Notes that [label] has occurred one more time.
  static void count(String label) {
    if (!enabled) return;

    _counts.update(label, (count) => count + 1, ifAbsent: () => 1);
  }

  /// Begins measuring the elapsed time between this call and a subsequent
  /// matching call to [end()].
  ///
  /// Works like a stack: A call to [end()] always completes the most recent
  /// [begin()].
  ///
  /// Multiple calls to [begin()]/[end()] with the same label accumulate their
  /// total time. Time is always inclusive. In other words, the time spent in
  /// a subsequent call to [begin()]/[end()] before this call's [end()] is not
  /// subtracted from this one.
  ///
  /// Also, no attempt is made to account for re-entrancy, so the accumulated
  /// time may be greater than the wall clock time if there are recursive calls
  /// that use the same label.
  static void begin(String label) {
    if (!enabled) return;

    // Indent to show nesting of profiled regions.
    label = '${'  ' * _running.length}$label';

    _running.add((label, Timeline.now));

    // Add the label eagerly to the map so that labels are printed in the
    // order they were began.
    _accumulatedTimes.putIfAbsent(label, () => 0);
  }

  static void end(String _) {
    if (!enabled) return;

    var (label, start) = _running.removeLast();
    var elapsed = Timeline.now - start;
    _accumulatedTimes.update(label, (accumulated) => accumulated + elapsed);
  }

  /// Discards all recorded profiling data.
  static void reset() {
    if (!enabled) return;

    // Shouldn't be in the middle of profiling.
    assert(_running.isEmpty);

    _counts.clear();
    _running.clear();
    _accumulatedTimes.clear();
  }

  /// Prints a report of all recorded profiling information.
  static void report() {
    if (!enabled) return;

    // Should have finished everything by now.
    assert(_running.isEmpty);

    _showTable('Counts', _counts);
    _showTable('Times (ms)', _accumulatedTimes, milliseconds: true);
  }

  static void _showTable(String header, Map<String, int> data,
      {bool milliseconds = false}) {
    if (data.isEmpty) return;

    print('');
    print(header);

    var labels = data.keys.toList();
    var longestLabel =
        labels.fold(0, (length, label) => max(length, label.length));

    for (var label in labels) {
      String value;
      if (milliseconds) {
        value = (data[label]! / 1000).toStringAsFixed(3).padLeft(10);
      } else {
        value = data[label]!.toString().padLeft(8);
      }

      print('${label.padRight(longestLabel)} = $value');
    }
  }
}
