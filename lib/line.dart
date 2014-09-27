// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.writer;

import 'dart:math' as math;

/// The number of spaces in a single level of indentation.
const _SPACES_PER_INDENT = 2;

String getIndentString(int indentWidth) => _getSpaces(indentWidth * 2);

class Line {
  final List<LineToken> tokens = <LineToken>[];
  final int indentLevel;

  Line({this.indentLevel: 0}) {
    if (indentLevel > 0) indent(indentLevel);
  }

  void addSpace() {
    addSpaces(1);
  }

  void addSpaces(int n, {weight: Weight.normal}) {
    tokens.add(new SpaceToken(n, weight: weight));
  }

  void addToken(LineToken token) {
    tokens.add(token);
  }

  void clear() {
    tokens.clear();
  }

  bool isEmpty() => tokens.isEmpty;

  bool isWhitespace() => tokens.every((tok) => tok is SpaceToken);

  void indent(int n) {
    tokens.insert(0, new SpaceToken(n * _SPACES_PER_INDENT));
  }
}

class Weight {
  static const normal = nonbreaking - 1;

  /// The weight of a space after '=' in variable declaration or assignment.
  static const single = nonbreaking - 2;

  static const nonbreaking = 100000000;
}

/// A working piece of text used in calculating line breaks.
class Chunk {
  final int indent;
  final List<LineToken> tokens = <LineToken>[];

  Chunk(this.indent, [List<LineToken> tokens]) {
    this.tokens.addAll(tokens);
  }

  /// The combined length of all tokens in this chunk.
  int get length => tokens.fold(0, (len, token) => len + token.length);

  /// Whether this chunk contains any spaces.
  bool get hasAnySpace => tokens.any((token) => token is SpaceToken);

  /// Gets the minimum weight of any space in this chunk.
  int get minSpaceWeight {
    return tokens.fold(Weight.nonbreaking, (weight, token) {
      if (token is! SpaceToken) return weight;
      return math.min(weight, token.weight);
    });
  }

  int getLengthToSpaceWithWeight(int weight) {
    var length = 0;
    for (LineToken token in tokens) {
      if (token is SpaceToken && token.weight == weight) {
        break;
      }
      length += token.length;
    }
    return length;
  }

  void add(LineToken token) {
    tokens.add(token);
  }

  Chunk subChunk(int indentLevel, int start, [int end]) {
    List<LineToken> subTokens = tokens.sublist(start, end);
    return new Chunk(indentLevel, subTokens);
  }

  String toString() => tokens.join();
}

class LineToken {
  final String value;

  LineToken(this.value);

  String toString() => value;

  int get length => lengthLessNewlines(value);

  int lengthLessNewlines(String str) =>
      str.endsWith('\n') ? str.length - 1 : str.length;
}

class SpaceToken extends LineToken {
  /// The "weight" of the space token.
  ///
  /// Heavier spaces resist line breaks more than lighter ones.
  final int weight;

  SpaceToken(int n, {this.weight: Weight.normal}) :
      super(_getSpaces(n));
}

class NewlineToken extends LineToken {
  NewlineToken(String value) : super(value);
}

/// Returns a string of [n] spaces.
String _getSpaces(int n) {
  const SPACES = const [
    '',
    ' ',
    '  ',
    '   ',
    '    ',
    '     ',
    '      ',
    '       ',
    '        ',
    '         ',
    '          ',
    '           ',
    '            ',
    '             ',
    '              ',
    '               ',
    '                ',
  ];

  if (n < SPACES.length) return SPACES[n];
  return " " * n;
}
