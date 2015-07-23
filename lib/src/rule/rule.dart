// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.rule.rule;

import '../chunk.dart';
import '../fast_hash.dart';

/// A constraint that determines the different ways a related set of chunks may
/// be split.
abstract class Rule extends FastHash {
  /// The number of different states this rule can be in.
  ///
  /// Each state determines which set of chunks using this rule are split and
  /// which aren't. Values range from zero to one minus this. Value zero
  /// always means "no chunks are split" and increasing values by convention
  /// mean increasingly undesirable splits.
  int get numValues;

  /// The rule value that forces this rule into its maximally split state.
  ///
  /// By convention, this is the highest of the range of allowed values.
  int get fullySplitValue => numValues - 1;

  int get cost => Cost.normal;

  /// During line splitting [LineSplitter] sets this to the index of this
  /// rule in its list of rules.
  int index;

  /// The other [Rule]s that "surround" this one (and care about that fact).
  ///
  /// In many cases, if a split occurs inside an expression, surrounding rules
  /// also want to split too. For example, a split in the middle of an argument
  /// forces the entire argument list to also split.
  ///
  /// This tracks those relationships. If this rule splits, (sets its value to
  /// [fullySplitValue]) then all of the outer rules will also be set to their
  /// fully split value.
  ///
  /// This contains all direct as well as transitive relationships. If A
  /// contains B which contains C, C's outerRules contains both B and A.
  Iterable<Rule> get outerRules => _outerRules;
  final Set<Rule> _outerRules = new Set<Rule>();

  /// Adds [inner] as an inner rule of this rule if it cares about inner rules.
  ///
  /// When an inner rule splits, it forces any surrounding outer rules to also
  /// split.
  void contain(Rule inner) {
    if (!splitsOnInnerRules) return;
    inner._outerRules.add(this);
  }

  /// Whether this rule cares about rules that it contains.
  ///
  /// If `true` then inner rules will constrain this one and force it to split
  /// when they split. Otherwise, it can split independently of any contained
  /// rules.
  bool get splitsOnInnerRules => true;

  bool isSplit(int value, Chunk chunk);

  /// Given that this rule has [value], determine if [other]'s value should be
  /// constrained.
  ///
  /// Allows relationships between rules like "if I split, then this should
  /// split too". Returns a non-negative value to force [other] to take that
  /// value. Returns -1 to allow [other] to take any non-zero value. Returns
  /// null to not constrain other.
  int constrain(int value, Rule other) {
    // By default, any implied rule will be fully split if this one is fully
    // split.
    if (value == 0) return null;
    if (_outerRules.contains(other)) return other.fullySplitValue;

    return null;
  }

  String toString() => "$id";
}

/// A rule that always splits a chunk.
class HardSplitRule extends Rule {
  int get numValues => 1;

  /// It's always going to be applied, so there's no point in penalizing it.
  ///
  /// Also, this avoids doubled counting in literal blocks where there is both
  /// a split in the outer chunk containing the block and the inner hard split
  /// between the elements or statements.
  int get cost => 0;

  /// It's always split anyway.
  bool get splitsOnInnerRules => false;

  bool isSplit(int value, Chunk chunk) => true;

  String toString() => "Hard";
}

/// A basic rule that has two states: unsplit or split.
class SimpleRule extends Rule {
  /// Two values: 0 is unsplit, 1 is split.
  int get numValues => 2;

  final int cost;

  final bool splitsOnInnerRules;

  SimpleRule({int cost, bool splitsOnInnerRules})
      : cost = cost != null ? cost : Cost.normal,
        splitsOnInnerRules =
            splitsOnInnerRules != null ? splitsOnInnerRules : true;

  bool isSplit(int value, Chunk chunk) => value == 1;

  String toString() => "Simple${super.toString()}";
}
