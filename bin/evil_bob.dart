// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.bin.evil_bob;

import 'dart:io';
import 'dart:math' as math;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/scanner.dart';

import 'package:dart_style/formatter.dart';

final _stringChar = new RegExp("[\"']");

main(List<String> args) {
  var code = new File(args[0]).readAsStringSync();
  print(new EvilBob().unformat(code));
}

/// De-styles code by randomizing all whitespace.
class EvilBob implements AnalysisErrorListener {
  StringBuffer _output;
  final _random = new math.Random();

  void onError(AnalysisError error) {
    throw new FormatterException.forErrors([error]);
  }

  String unformat(String source) {
    var token = _tokenize(source);
    _output = new StringBuffer();

    _vurp();

    while (token.type != TokenType.EOF) {
//      print("${token.type} ${token.lexeme}");
      _write(token);
      token = token.next;
    }

    var result = _output.toString();
    _output = null;
    return result;
  }

  Token _tokenize(String source) {
    var reader = new CharSequenceReader(source);
    var scanner = new Scanner(null, reader, this);
    return scanner.tokenize();
  }

  void _writeComments(Token token) {
    var comment = token.precedingComments;

    while (comment != null) {
      _output.write(comment.lexeme);

      _vurp();

      // Have to terminate line comments with a newline.
      if (comment.lexeme.startsWith("//")) _output.write("\n");

      _vurp();

      comment = comment.next;
    }
  }

  void _write(Token token) {
    _writeComments(token);
    _output.write(token.lexeme);

    // Don't allow whitespace after "$" in a string.
    if (token.type == TokenType.STRING_INTERPOLATION_IDENTIFIER) return;

    // Don't add whitespace to the middle of a string before an interpolation.
    if (token.next.type == TokenType.STRING_INTERPOLATION_EXPRESSION ||
        token.next.type == TokenType.STRING_INTERPOLATION_IDENTIFIER) {
      return;
    }

    // Don't add whitespace after an interpolation.
    if (token.next.type == TokenType.STRING &&
        (!token.next.lexeme.startsWith(_stringChar) || token.next.length == 1)) {
      return;
    }

    if (token.end != token.next.offset) {
      // If there is whitespace between the tokens, it may be needed, so
      // ensure it's at least preserved.
      _vomit();
    } else {
      // May even add whitespace between tokens that didn't have any.
      _vurp();
    }
  }

  /// Randomly output some whitespace, or possibly nothing.
  void _vurp() {
    if (_random.nextBool()) return;
    _vomit();
  }

  /// Randomly output some whitespace.
  void _vomit() {
    // TODO(rnystrom): Output newlines in some cases.
    for (var i = 0; i < _random.nextInt(2) + 1; i++) {
      _output.write("    \t"[_random.nextInt(5)]);
    }
  }
}
