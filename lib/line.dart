// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.writer;

import 'dart:math' as math;

/// The number of spaces in a single level of indentation.
const SPACES_PER_INDENT = 2;

class Line {
  final List<LineToken> tokens = <LineToken>[];
  int indent;

  /// Returns `true` if the line contains no visible text.
  bool get isEmpty => tokens.isEmpty;

  Line({this.indent: 0});

  /// Add [token] to the end of this line.
  void add(LineToken token) {
    // Should not add leading whitespace.
    assert(tokens.isNotEmpty || token is! SpaceToken);

    tokens.add(token);
  }

  void clearIndentation() {
    assert(tokens.isEmpty);

    indent = 0;
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

  /// Gets the indentation before this chunk as a string of whitespace.
  String get indentString {
    var spaces = indent * SPACES_PER_INDENT;
    // TODO(rnystrom): Profile and see if this optimization is worth it.
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

    if (spaces < SPACES.length) return SPACES[spaces];
    return " " * spaces;
  }

  Chunk(this.indent, [List<LineToken> tokens]) {
    this.tokens.addAll(tokens);
  }

  /// The combined length of all tokens in this chunk.
  int get length => tokens.fold(indent * SPACES_PER_INDENT,
      (len, token) => len + token.length);

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

  /// The number of characters in the token's [value].
  int get length => value.length;

  LineToken(this.value);

  String toString() => value;
}

class SpaceToken extends LineToken {
  /// The "weight" of the space token.
  ///
  /// Heavier spaces resist line breaks more than lighter ones.
  final int weight;

  SpaceToken({bool zeroWidth: false, this.weight: Weight.normal}) :
      super(zeroWidth ? "" : " ");
}
