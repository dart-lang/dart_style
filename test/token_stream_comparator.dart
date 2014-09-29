// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.test.token_stream_comparator;

import 'package:dart_style/dart_style.dart';

import 'package:analyzer/src/generated/scanner.dart';
import 'package:analyzer/src/generated/source.dart';

// Compares two token streams.  Used for sanity checking formatted results.
class TokenStreamComparator {
  final LineInfo lineInfo;
  Token token1, token2;

  TokenStreamComparator(this.lineInfo, this.token1, this.token2);

  /// Verify that these two token streams are equal.
  verifyEquals() {
    while (!_tokenIs(token1, TokenType.EOF)) {
      _checkPrecedingComments();
      if (!checkTokens()) _fail(token1, token2);
      advance();
    }

    if (!_tokenIs(token2, TokenType.EOF) &&
        !(_tokenIs(token2, TokenType.CLOSE_SQUARE_BRACKET) &&
            _tokenIs(token2.next, TokenType.EOF))) {
      throw new FormatterException('Expected "EOF" but got "${token2}".');
    }
  }

  _checkPrecedingComments() {
    var comment1 = token1.precedingComments;
    var comment2 = token2.precedingComments;
    while (comment1 != null) {
      if (comment2 == null) {
        throw new FormatterException(
            'Expected comment, "$comment1", at ${describeLocation(token1)}, '
            'but got none.');
      }

      if (comment1.lexeme.trim() != comment2.lexeme.trim()) {
        _fail(comment1, comment2);
      }

      comment1 = comment1.next;
      comment2 = comment2.next;
    }

    if (comment2 != null) {
      throw new FormatterException(
          'Unexpected comment, "$comment2", at ${describeLocation(token2)}.');
    }
  }

  _fail(t1, t2) {
    throw new FormatterException(
        'Expected "${t1}" but got "$t2", at ${describeLocation(t1)}.');
  }

  String describeLocation(Token token) => lineInfo == null ? '<unknown>' :
      'Line: ${lineInfo.getLocation(token.offset).lineNumber}, '
      'Column: ${lineInfo.getLocation(token.offset).columnNumber}';

  advance() {
    token1 = token1.next;
    token2 = token2.next;
  }

  bool checkTokens() {
    if (token1 == null || token2 == null) return false;
    if (token1 == token2 || token1.lexeme == token2.lexeme) return true;

    // '[' ']' => '[]'.
    if (_tokenIs(token1, TokenType.OPEN_SQUARE_BRACKET) &&
        _tokenIs(token1.next, TokenType.CLOSE_SQUARE_BRACKET) &&
        _tokenIs(token2, TokenType.INDEX)) {
      token1 = token1.next;
      return true;
    }

    // '>' '>' => '>>'.
    if (_tokenIs(token1, TokenType.GT) &&
        _tokenIs(token1.next, TokenType.GT) &&
        _tokenIs(token2, TokenType.GT_GT)) {
      token1 = token1.next;
      return true;
    }

    return false;
  }

  /// Returns `true` if [token] is of [type].
  bool _tokenIs(Token token, TokenType type) =>
      token != null && token.type == type;
}
