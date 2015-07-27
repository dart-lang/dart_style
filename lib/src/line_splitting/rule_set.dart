// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_splitting.rule_set;

import '../rule/rule.dart';

/// An optimized data structure for storing a set of values for some rules.
///
/// This conceptually behaves roughly like a `Map<Rule, int>`, but is much
/// faster since it avoids hashing. Instead, it assumes the line splitter has
/// provided an ordered list of [Rule]s and that each rule's [index] field has
/// been set to point to the rule in the list.
///
/// Internally, this then just stores the values in a sparse list whose indices
/// are the indices of the rules.
class RuleSet {
  List<int> _values;

  RuleSet(int numRules) : this._(new List(numRules));

  RuleSet._(this._values);

  /// Returns `true` of [rule] is bound in this set.
  bool contains(Rule rule) => _values[rule.index] != null;

  /// Gets the bound value for [rule] or `0` if it is not bound.
  int getValue(Rule rule) {
    var value = _values[rule.index];
    if (value != null) return value;

    return 0;
  }

  /// Invokes [callback] for each rule in [rules] with the rule's value, which
  /// will be `null` if it is not bound.
  void forEach(List<Rule> rules, callback(Rule rule, int value)) {
    var i = 0;
    for (var rule in rules) {
      var value = _values[i];
      if (value != null) callback(rule, value);
      i++;
    }
  }

  /// Creates a new [RuleSet] with the same bound rule values as this one.
  RuleSet clone() => new RuleSet._(_values.toList(growable: false));

  /// Binds [rule] to [value] then checks to see if that violates any
  /// constraints.
  ///
  /// Returns `true` if all constraints between the bound rules are valid. Even
  /// if not, this still modifies the [RuleSet].
  ///
  /// If an unbound rule gets constrained to `-1` (meaning it must split, but
  /// can split any way it wants), invokes [onSplitRule] with it.
  bool tryBind(List<Rule> rules, Rule rule, int value, onSplitRule(Rule rule)) {
    _values[rule.index] = value;

    // Test this rule against the other rules being bound.
    for (var other in rules) {
      if (rule == other) continue;

      var otherValue = _values[other.index];
      var constraint = rule.constrain(value, other);

      if (otherValue == null) {
        // The other rule is unbound, so see if we can constrain it eagerly to
        // a value now.
        if (constraint == -1) {
          // If we know the rule has to split and there's only one way it can,
          // just bind that.
          if (other.numValues == 2) {
            if (!tryBind(rules, other, 1, onSplitRule)) return false;
          } else {
            onSplitRule(other);
          }
        } else if (constraint != null) {
          // Bind the other rule to its value and recursively propagate its
          // constraints.
          if (!tryBind(rules, other, constraint, onSplitRule)) return false;
        }
      } else {
        // It's already bound, so see if the new rule's constraint disallows
        // that value.
        if (constraint == -1) {
          if (otherValue == 0) return false;
        } else if (constraint != null) {
          if (otherValue != constraint) return false;
        }

        // See if the other rule's constraint allows us to use this value.
        constraint = other.constrain(otherValue, rule);
        if (constraint == -1) {
          if (value == 0) return false;
        } else if (constraint != null) {
          if (value != constraint) return false;
        }
      }
    }

    return true;
  }

  String toString() =>
      _values.map((value) => value == null ? "?" : value).join(" ");
}

/// For each chunk, this tracks if it has been split and, if so, what the
/// chosen column is for the following line.
///
/// Internally, this uses a list where each element corresponds to the column
/// of the chunk at that index in the chunk list, or `null` if that chunk did
/// not split. This had about a 10% perf improvement over using a [Set] of
/// splits.
class SplitSet {
  List<int> _columns;

  /// The cost of the solution that led to these splits.
  int get cost => _cost;
  int _cost;

  /// Creates a new empty split set for a line with [numChunks].
  SplitSet(int numChunks) : _columns = new List(numChunks - 1);

  /// Marks the line after chunk [index] as starting at [column].
  void add(int index, int column) {
    _columns[index] = column;
  }

  /// Returns `true` if the chunk at [splitIndex] should be split.
  bool shouldSplitAt(int index) =>
      index < _columns.length && _columns[index] != null;

  /// Gets the zero-based starting column for the chunk at [index].
  int getColumn(int index) => _columns[index];

  /// Sets the resulting [cost] for the splits.
  ///
  /// This can only be called once.
  void setCost(int cost) {
    assert(_cost == null);
    _cost = cost;
  }

  String toString() {
    var result = [];
    for (var i = 0; i < _columns.length; i++) {
      if (_columns[i] != null) {
        result.add("$i:${_columns[i]}");
      }
    }

    return result.join(" ");
  }
}
