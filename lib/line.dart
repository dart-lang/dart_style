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

  void addSpaces(int n, {breakWeight: DEFAULT_SPACE_WEIGHT}) {
    tokens.add(new SpaceToken(n, breakWeight: breakWeight));
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

const DEFAULT_SPACE_WEIGHT = UNBREAKABLE_SPACE_WEIGHT - 1;
/// The weight of a space after '=' in variable declaration or assignment
const SINGLE_SPACE_WEIGHT = UNBREAKABLE_SPACE_WEIGHT - 2;
const UNBREAKABLE_SPACE_WEIGHT = 100000000;

/// A working piece of text used in calculating line breaks.
class Chunk {
  final int indent;
  final List<LineToken> tokens = <LineToken>[];

  Chunk(this.indent, [List<LineToken> tokens]) {
    this.tokens.addAll(tokens);
  }

  int get length {
    return tokens.fold(0, (len, token) => len + token.length);
  }

  int getLengthToSpaceWithWeight(int weight) {
    var length = 0;
    for (LineToken token in tokens) {
      if (token is SpaceToken && token.breakWeight == weight) {
        break;
      }
      length += token.length;
    }
    return length;
  }

  void add(LineToken token) {
    tokens.add(token);
  }

  bool hasInitializerSpace() {
    return tokens.any((token) => token is SpaceToken &&
        token.breakWeight == SINGLE_SPACE_WEIGHT);
  }

  bool hasAnySpace() => tokens.any((token) => token is SpaceToken);

  int findMinSpaceWeight() {
    var minWeight = UNBREAKABLE_SPACE_WEIGHT;
    for (var token in tokens) {
      if (token is SpaceToken) {
        minWeight = math.min(minWeight, token.breakWeight);
      }
    }
    return minWeight;
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
  final int breakWeight;

  SpaceToken(int n, {this.breakWeight: DEFAULT_SPACE_WEIGHT}) :
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
