// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart_style/src/analysis_options/merge_options.dart';
import 'package:test/test.dart';

void main() {
  group('merge()', () {
    test('Map', () {
      _testMerge(
        {
          'one': true,
          'two': false,
          'three': {
            'nested': {'four': true, 'six': true}
          }
        },
        {
          'three': {
            'nested': {'four': false, 'five': true},
            'five': true
          },
          'seven': true
        },
        {
          'one': true,
          'two': false,
          'three': {
            'nested': {'four': false, 'five': true, 'six': true},
            'five': true
          },
          'seven': true
        },
      );
    });

    test('List', () {
      _testMerge(
        [1, 2, 3],
        [2, 3, 4, 5],
        [1, 2, 3, 4, 5],
      );
    });

    test('List with promotion', () {
      _testMerge(
        ['one', 'two', 'three'],
        {'three': false, 'four': true},
        {'one': true, 'two': true, 'three': false, 'four': true},
      );
      _testMerge(
        {'one': false, 'two': false},
        ['one', 'three'],
        {'one': true, 'two': false, 'three': true},
      );
    });

    test('Map with list promotion', () {
      _testMerge(
        {
          'one': ['a', 'b', 'c']
        },
        {
          'one': {'a': true, 'b': false}
        },
        {
          'one': {'a': true, 'b': false, 'c': true}
        },
      );
    });

    test('Map with no promotion', () {
      _testMerge(
        {
          'one': ['a', 'b', 'c']
        },
        {
          'one': {'a': 'foo', 'b': 'bar'}
        },
        {
          'one': {'a': 'foo', 'b': 'bar'}
        },
      );
    });

    test('Map with no promotion 2', () {
      _testMerge(
        {
          'one': {'a': 'foo', 'b': 'bar'}
        },
        {
          'one': ['a', 'b', 'c']
        },
        {
          'one': ['a', 'b', 'c']
        },
      );
    });

    test('Other values', () {
      _testMerge(1, 2, 2);
      _testMerge(1, 'foo', 'foo');
      _testMerge({'foo': 1}, 'foo', 'foo');
    });
  });
}

void _testMerge(Object defaults, Object overrides, Object expected) {
  expect(merge(defaults, overrides), equals(expected));
}
