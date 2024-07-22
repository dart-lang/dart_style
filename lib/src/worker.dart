// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'cli/formatter_options.dart';
import 'dart_formatter.dart';
import 'debug.dart' as debug;
import 'exceptions.dart';
import 'profile.dart';
import 'short/style_fix.dart';
import 'source_code.dart';

class Worker {
  static Future<Worker> start(int id) async {
    Profile.begin2('start worker', '$id');

    var connection = Completer<(ReceivePort, SendPort)>.sync();

    // TODO: Docs.
    var initPort = RawReceivePort();
    initPort.handler = (Object? initialMessage) {
      var requestPort = initialMessage as SendPort;
      connection.complete((
        ReceivePort.fromRawReceivePort(initPort),
        requestPort,
      ));
    };

    await Isolate.spawn(
        _startRemoteIsolate, (workerId: id, sendPort: initPort.sendPort));

    var (receivePort, sendPort) = await connection.future;

    Profile.end2('start worker', '$id');
    return Worker._(id, sendPort, receivePort);
  }

  // runs in isolate
  static void _startRemoteIsolate(({int workerId, SendPort sendPort}) message) {
    if (debug.traceWorkers) {
      debug.log('_startRemoteIsolate #${message.workerId}');
    }

    var receivePort = ReceivePort();
    message.sendPort.send(receivePort.sendPort);
    _processRequests(message.workerId, receivePort, message.sendPort);
  }

  // runs in isolate
  static void _processRequests(
      int workerId, ReceivePort receivePort, SendPort sendPort) {
    receivePort.listen((dynamic message) {
      switch (message) {
        case 'quit':
          if (debug.traceWorkers) {
            debug.log('Quitting worker #$workerId...');
          }

          receivePort.close();

        case _WorkerFormatRequest request:
          Profile.end2('send format request', request.filePath);
          if (debug.traceWorkers) {
            debug.log('Worker #$workerId received request to format '
                '${request.filePath}...');
          }

          try {
            Profile.begin2('format', request.filePath);
            var response = _processFormatRequest(request);
            Profile.end2('format', request.filePath);

            Profile.begin2('send format response', request.filePath);
            sendPort.send(response);
          } catch (error) {
            sendPort.send(RemoteError(error.toString(), ''));
          }

        default:
          throw ArgumentError('Unknown request $message');
      }
    });
  }

  static WorkerFormatResponse _processFormatRequest(
      _WorkerFormatRequest request) {
    Profile.begin2('Worker._processFormatRequest()', request.filePath);
    try {
      var source = SourceCode(request.source, uri: request.filePath);

      var formatter = DartFormatter(
          indent: request.indent,
          pageWidth: request.pageWidth,
          fixes: request.fixes,
          experimentFlags: request.experimentFlags);
      try {
        var output = formatter.formatSource(source);

        // TODO: Temporary code to replace the actual formatting logic with some
        // other CPU-intensive task. Comment out the above line and uncomment this
        // block to try it.
        /*
      // Do some dumb slow computation.
      int fib(int n) {
        if (n <= 1) return n;
        return fib(n - 2) + fib(n - 1);
      }

      var x = fib(33);
      if (x == 3) throw '!';
      var output = source;
      */

        return (
          path: request.filePath,
          text: output.text,
          isChanged: source.text != output.text,
          selectionStart: output.selectionStart,
          selectionLength: output.selectionLength
        );
      } on FormatterException catch (err) {
        // TODO: Probably want all error reporting to happen on main isolate.
        var color = Platform.operatingSystem != 'windows' &&
            stdioType(stderr) == StdioType.terminal;

        stderr.writeln(err.message(color: color));
      } on UnexpectedOutputException catch (err) {
        // TODO: Probably want all error reporting to happen on main isolate.
        // TODO: Should show display path.
        stderr.writeln(
            '''Hit a bug in the formatter when formatting ${request.filePath}.
$err
Please report at github.com/dart-lang/dart_style/issues.''');
      } catch (err, stack) {
        // TODO: Probably want all error reporting to happen on main isolate.
        // TODO: Should show display path.
        stderr.writeln(
            '''Hit a bug in the formatter when formatting ${request.filePath}.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''');
      }

      // TODO: Temp.
      return (
        path: request.filePath,
        text: 'ERROR',
        isChanged: false,
        selectionStart: null,
        selectionLength: null
      );
    } finally {
      Profile.end2('Worker._processFormatRequest()', request.filePath);
    }
  }

  final int _id;

  final SendPort _requests;
  final ReceivePort _responses;

  /// If this worker is currently formatting, this will be the Completer that
  /// completes with the eventual result.
  ///
  /// Otherwise, if the worker is idle, this is `null`.
  Completer<WorkerFormatResponse>? _pendingRequest;

  Worker._(this._id, this._requests, this._responses) {
    _responses.listen(_handleResponse);
  }

  Future<WorkerFormatResponse> requestFormat(
      FormatterOptions options, String filePath, String source) async {
    // assert(!_isWorking, 'Worker has already quit.');
    assert(_pendingRequest == null, '$this is already formatting.');

    if (debug.traceWorkers) {
      debug.log('$this requestFormat($filePath)');
    }

    var completer = Completer<WorkerFormatResponse>();
    _pendingRequest = completer;

    if (debug.traceWorkers) {
      debug.log('$this init pendingRequest for $filePath');
    }

    Profile.begin2('send format request', filePath);
    _requests.send((
      indent: options.indent,
      pageWidth: options.pageWidth,
      fixes: options.fixes,
      experimentFlags: options.experimentFlags,
      filePath: filePath,
      source: source,
    ));

    return await completer.future;
  }

  // main isolate
  void _handleResponse(dynamic message) {
    if (debug.traceWorkers) {
      debug.log('$this _handleResponse()');
    }

    switch (message) {
      case RemoteError error:
        // print('$this _handleResponse error $error');
        _pendingRequest!.completeError(error);
        _pendingRequest = null;
      // print('$this _handleResponse() error clear pendingRequest');

      case WorkerFormatResponse response:
        Profile.end2('send format response', response.path);

        // print('$this _handleResponse response ${response.path}');
        _pendingRequest!.complete(response);
        _pendingRequest = null;
      // print('$this _handleResponse() clear pendingRequest for '
      //     '${response.path}');

      // case _WorkerErrorResponse(type: _ErrorType.formatter):
      //   _currentRequest!.completeError(error);
      //   _currentRequest = null;

      default:
        throw ArgumentError('Unknown response $message');
    }
  }

  void quit() {
    if (debug.traceWorkers) {
      debug.log('Quit $this');
    }

    _requests.send('quit');
    _responses.close();
  }

  @override
  String toString() => 'Worker #$_id';
}

typedef _WorkerFormatRequest = ({
  int indent,
  int pageWidth,
  List<StyleFix> fixes,
  List<String> experimentFlags,
  String filePath,
  String source,
});

typedef WorkerFormatResponse = ({
  // TODO: Just for debug output.
  String path,
  String text,
  bool isChanged,
  int? selectionStart,
  int? selectionLength
});
