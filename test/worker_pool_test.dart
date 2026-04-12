// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'package:dart_style/src/back_end/worker_pool.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  test('WorkerPool.close waits for callbacks', () async {
    var pool = WorkerPool(size: 1); // Pool size 1

    // We cannot easily override the batch size via environment variables here
    // because it is read once into a static final field in WorkerPool.
    // Instead, we add enough tasks (20) to fill a default batch and make it
    // active.
    var testFile = 'test/worker_pool_test.dart';

    for (var i = 0; i < pool.maxBacklog; i++) {
      unawaited(
        pool.add(
          uri: testFile,
          languageVersion: Version(3, 0, 0),
          indent: 0,
          pageWidth: 80,
          trailingCommas: null,
          experimentFlags: [],
          onResult: (_) {},
        ),
      );
    }

    // The first batch is now active and using the single pool resource.

    var callbackCalled = false;
    var success = true;

    // Add one more task that will be queued since the pool is busy.
    unawaited(
      pool.add(
        uri: 'non_existent_file.dart',
        languageVersion: Version(3, 0, 0),
        indent: 0,
        pageWidth: 80,
        trailingCommas: null,
        experimentFlags: [],
        onResult: (response) {
          callbackCalled = true;
          if (response.error != null) {
            success = false;
          }
        },
      ),
    );

    // Immediately close the pool. This flushes the pending request,
    // which will be queued in the pool. We want to verify that close()
    // waits for this queued request to complete its callback.
    await pool.close();

    // Verify that the callback was called and success was set to false.
    expect(callbackCalled, isTrue, reason: 'Callback should be called');
    expect(success, isFalse, reason: 'Success should be false on error');
  });
}
