// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:pool/pool.dart';
import 'package:pub_semver/pub_semver.dart';

import '../dart_formatter.dart';
import '../exceptions.dart';
import '../source_code.dart';

typedef _PendingRequest = ({
  _WorkerRequest request,
  void Function(WorkerResponse) callback,
});

/// A pool of long-lived isolates that can format Dart source code in parallel.
final class WorkerPool {
  /// The list of free worker ports.
  final List<SendPort> _freeWorkers = [];

  /// The pool to limit concurrency.
  final Pool _pool;

  /// Whether the pool is being shut down.
  bool _isClosed = false;

  /// Queue to buffer requests until we have a full batch.
  final List<_PendingRequest> _pending = [];

  /// List of futures for active batches to ensure we wait for them on close.
  final List<Future<void>> _activeBatches = [];

  static final _batchSize = _getBatchSize();

  /// The number of requests currently in memory (pending or in flight).
  int _inMemoryCount = 0;

  /// The maximum number of requests allowed in memory before throttling.
  final int maxBacklog;

  /// Completer to pause the producer when the backlog is full.
  Completer<void>? _throttleCompleter;

  /// Creates a worker pool with [size] isolates.
  ///
  /// If [size] is not given, defaults to the 'FORMAT_POOL_SIZE' environment
  /// variable if set, otherwise [Platform.numberOfProcessors] - 1,
  /// with a minimum of 1.
  WorkerPool({int? size})
    : _pool = Pool(size ?? _getPoolSize()),
      maxBacklog = _batchSize * ((size ?? _getPoolSize()) + 1) {
    if (_batchSize < 1) {
      throw ArgumentError('FORMAT_BATCH_SIZE must be >= 1, got $_batchSize');
    }
  }

  /// Adds a request to the pool.
  ///
  /// The [onResult] callback will be called when this specific request is
  /// complete.
  ///
  /// The returned [Future] completes when the pool has capacity to accept more
  /// requests. If the pool's backlog grows too large, this method will pause
  /// the caller to apply backpressure and prevent excessive memory usage from
  /// eagerly reading file contents.
  Future<void> add({
    required String uri,
    required Version languageVersion,
    required int indent,
    required int pageWidth,
    required TrailingCommas? trailingCommas,
    required List<String> experimentFlags,
    required void Function(WorkerResponse) onResult,
  }) async {
    if (_isClosed) throw StateError('WorkerPool is closed');

    _inMemoryCount++;

    var request = _WorkerRequest(
      uri: uri,
      languageVersion: languageVersion,
      indent: indent,
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
      experimentFlags: experimentFlags,
    );

    void wrappedCallback(WorkerResponse response) {
      _inMemoryCount--;
      if (_inMemoryCount < maxBacklog && _throttleCompleter != null) {
        var c = _throttleCompleter!;
        _throttleCompleter = null;
        c.complete();
      }
      onResult(response);
    }

    _pending.add((request: request, callback: wrappedCallback));

    if (_pending.length >= _batchSize) {
      _flush();
    }

    if (_inMemoryCount >= maxBacklog) {
      _throttleCompleter ??= Completer<void>();
      return _throttleCompleter!.future;
    }
  }

  /// Sends a batch of requests to a worker.
  void _flush() {
    if (_pending.isEmpty) return;

    var currentBatch = _pending.toList();
    _pending.clear();

    var requests = currentBatch.map((_PendingRequest e) => e.request).toList();

    // Run the batch in the background. The pool will limit concurrency.
    _formatBatch(requests, currentBatch);
  }

  /// Spawns a new worker isolate.
  Future<SendPort> _spawnWorker() async {
    var completer = Completer<SendPort>();
    var receivePort = ReceivePort();

    receivePort.listen((message) {
      if (message is SendPort) {
        receivePort.close();
        completer.complete(message);
      }
    });

    await Isolate.spawn(_workerEntry, receivePort.sendPort);
    return completer.future;
  }

  /// Formats a batch of files in a worker isolate.
  Future<void> _formatBatch(
    List<_WorkerRequest> requests,
    List<_PendingRequest> batch,
  ) async {
    var future = _pool.withResource(() async {
      var worker = _freeWorkers.isNotEmpty
          ? _freeWorkers.removeLast()
          : await _spawnWorker();
      var responsePort = ReceivePort();

      try {
        worker.send((requests, responsePort.sendPort));
        var response = await responsePort.first;
        var responses = response as List<WorkerResponse>;
        for (var i = 0; i < batch.length; i++) {
          batch[i].callback(responses[i]);
        }
      } catch (e) {
        for (var i = 0; i < batch.length; i++) {
          batch[i].callback(WorkerResponse(error: e.toString()));
        }
      } finally {
        responsePort.close();
        if (_isClosed) {
          worker.send(null); // Signal worker to exit.
        } else {
          _freeWorkers.add(worker);
        }
      }
    });

    _activeBatches.add(future);
    try {
      await future;
    } finally {
      _activeBatches.remove(future);
    }
  }

  /// Closes the pool and shuts down all worker isolates.
  Future<void> close() async {
    _isClosed = true;
    _flush();
    await Future.wait(_activeBatches);
    await _pool.close();
    for (var worker in _freeWorkers) {
      worker.send(null);
    }
    _freeWorkers.clear();
  }

  static void _workerEntry(SendPort mainSendPort) {
    var receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      if (message == null) {
        receivePort.close();
        return;
      }

      var (requests, responseSendPort) =
          message as (List<_WorkerRequest>, SendPort);
      var responses = <WorkerResponse>[];

      for (var request in requests) {
        var formatter = DartFormatter(
          languageVersion: request.languageVersion,
          indent: request.indent,
          pageWidth: request.pageWidth,
          trailingCommas: request.trailingCommas,
          experimentFlags: request.experimentFlags,
        );

        try {
          var file = File(request.uri);
          var sourceText = file.readAsStringSync();
          var source = SourceCode(sourceText, uri: request.uri);
          var output = formatter.formatSource(source);

          responses.add(
            WorkerResponse(
              text: output.text,
              selectionStart: output.selectionStart,
              selectionLength: output.selectionLength,
              changed: sourceText != output.text,
            ),
          );
        } on FormatterException catch (err) {
          responses.add(
            WorkerResponse(error: err.message(), isFormatterException: true),
          );
        } catch (err, stack) {
          responses.add(
            WorkerResponse(error: err.toString(), stackTrace: stack.toString()),
          );
        }
      }

      responseSendPort.send(responses);
    });
  }
}

/// The parameters for a single formatting task.
final class _WorkerRequest {
  final String uri;
  final Version languageVersion;
  final int indent;
  final int pageWidth;
  final TrailingCommas? trailingCommas;
  final List<String> experimentFlags;

  _WorkerRequest({
    required this.uri,
    required this.languageVersion,
    required this.indent,
    required this.pageWidth,
    required this.trailingCommas,
    required this.experimentFlags,
  });
}

/// The result of a single formatting task.
final class WorkerResponse {
  final String? text;
  final int? selectionStart;
  final int? selectionLength;
  final String? error;
  final String? stackTrace;
  final bool isFormatterException;
  final bool changed;

  WorkerResponse({
    this.text,
    this.selectionStart,
    this.selectionLength,
    this.error,
    this.stackTrace,
    this.isFormatterException = false,
    this.changed = false,
  });
}

int _getPoolSize() {
  var env = Platform.environment['FORMAT_POOL_SIZE'];
  var n = Platform.numberOfProcessors;
  var size = (n / 3).round();
  if (env != null) {
    size = int.tryParse(env) ?? size;
  }
  return size.clamp(1, 32);
}

int _getBatchSize() {
  var env = Platform.environment['FORMAT_BATCH_SIZE'];
  var size = 20;
  if (env != null) {
    size = int.tryParse(env) ?? size;
  }
  return size.clamp(1, 500);
}
