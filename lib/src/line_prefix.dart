// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.line_printer;

import 'chunk.dart';
import 'nesting.dart';
import 'rule.dart';

/// A prefix of a series of chunks, which in turn can be considered a key to
/// describe the suffix of the remaining chunks that follows it.
///
/// This is used by the splitter to memoize suffixes whose best splits have
/// previously been calculated. For each unique [LinePrefix], there will be a
/// single set of best splits for the remainder of the line following it.
class LinePrefix {
  /// The number of chunks in the prefix.
  ///
  /// The suffix is the remaining chunks starting at index [length].
  final int length;

  /// The [Rule]s that apply to chunks in the prefix and have thus already had
  /// their values selected.
  ///
  /// Does not include rules that do not also appear in the suffix since they
  /// don't affect the suffix.
  final Map<Rule, int> ruleValues;

  /// The [Rule]s in the prefix whose value was non-zero and that imply rules
  /// appearing in the suffix.
  ///
  /// Ensures that when one rule splitting forces other rules to split that
  /// the previous choice to split or not on the former rule is preserved for
  /// the latter ones.
  final Set<Rule> impliedRules;

  /// The nested expressions in the prefix that are still open at the beginning
  /// of the suffix.
  ///
  /// For example, if the line is `outer(inner(argument))`, and the prefix is
  /// `outer(inner(`, the nesting stack will be two levels deep.
  final NestingStack _nesting;

  /// The depth of indentation caused expression nesting.
  int get nestingIndent => _nesting.indent;

  /// Creates a new zero-length prefix whose suffix is the entire line.
  LinePrefix([int length = 0])
      : this._(length, {}, new Set(), new NestingStack());

  LinePrefix._(this.length, this.ruleValues, this.impliedRules, this._nesting) {
    assert(_nesting != null);
  }

  bool operator ==(other) {
    if (other is! LinePrefix) return false;

    if (length != other.length) return false;
    if (_nesting != other._nesting) return false;

    // Compare rule values.
    if (ruleValues.length != other.ruleValues.length) return false;

    for (var key in ruleValues.keys) {
      if (other.ruleValues[key] != ruleValues[key]) return false;
    }

    // Compare implied sets.
    if (impliedRules.length != other.impliedRules.length) return false;
    for (var implied in impliedRules) {
      if (!other.impliedRules.contains(implied)) return false;
    }

    return true;
  }

  // TODO(rnystrom): Can we make this more effective?
  int get hashCode => length.hashCode ^ _nesting.hashCode;

  /// Whether this prefix specifies a value for a rule that does not allow any
  /// more splits to occur.
  ///
  /// This lets inner splitting choices preserve the requirement that a rule
  /// cannot contain any splits.
  bool get allowsSplits {
    // TODO(rnystrom): Cache this?
    for (var rule in ruleValues.keys) {
      // TODO(bob): Need to distinguish between the rules used for collections
      // et. al. that do want this behavior and the ones for things like binary
      // operators that may not. Or do we?
      if (rule is SimpleRule && !rule.isSplit(ruleValues[rule], null)) {
        return false;
      }
    }

    return true;
  }

  /// Create a new LinePrefix one chunk longer than this one using [value] for
  /// the next chunk's rule, and assuming that we do not split before that
  /// chunk.
  LinePrefix addChunk(List<Chunk> chunks, int value) {
    // We aren't splitting on the new chunk, so preserve the previous nesting.
    var updatedRules = {};
    var implied = new Set();
    _advanceRuleValues(chunks, value, updatedRules, implied);
    return new LinePrefix._(length + 1, updatedRules, implied, _nesting);
  }

  // TODO(bob): Doc.
  Iterable<LinePrefix> addSplit(List<Chunk> chunks, int value) {
    var updatedRules = {};
    var implied = new Set();
    _advanceRuleValues(chunks, value, updatedRules, implied);

    // TODO(bob): Can we hoist this out to splitter and avoid making lists for
    // the cases where it's not needed?
    var chunk = chunks[length];
    if (!chunk.isInExpression) {
      // The split is in statement context so there is no nesting stack.
      return [
        new LinePrefix._(length + 1, updatedRules, implied, new NestingStack())
      ];
    } else {
      // The nesting stack has changed, so return all of the possible ways it
      // can be different.
      return _nesting.applySplit(chunk).map((nesting) =>
          new LinePrefix._(length + 1, updatedRules, implied, nesting));
    }
  }

  /// Gets the leading indentation of the newline that immediately follows
  /// this prefix.
  ///
  /// Takes into account the indentation of the previous split and any
  /// additional indentation from wrapped nested expressions.
  int getNextLineIndent(List<Chunk> chunks, int indent) {
    // TODO(rnystrom): This could be cached at construction time, which may be
    // faster.
    // Get the initial indentation of the line immediately after the prefix,
    // ignoring any extra indentation caused by nested expressions.
    if (length > 0) indent = chunks[length - 1].indent;

    return indent + _nesting.indent;
  }

  String toString() {
    var result = "prefix $length";
    if (_nesting.indent != 0) result += " nesting $_nesting";
    if (ruleValues.isNotEmpty) {
      var rules = ruleValues.keys
          .map((key) => "$key:${ruleValues[key]}")
          .join(" ");

      result +=" rules $rules";
    }
    return result;
  }

  /// Fills in [updatedRules] and [implied] with the results for a new prefix
  /// based on whose length has been extended by one and whose rule on the new
  /// last chunk has [value].
  void _advanceRuleValues(List<Chunk> chunks, int value,
      Map<Rule, int> updatedRules, Set<Rule> implied) {
    // TODO(bob): Precalculate and cache these.
    // Get the rules that appear in both in and after the new prefix. These are
    // the rules that already have values that the suffix needs to honor.
    var prefix = chunks.take(length + 1).map((chunk) => chunk.rule).toSet();
    var suffix = chunks.skip(length + 1).map((chunk) => chunk.rule).toSet();

    var nextRule = chunks[length].rule;

    // Fill in the rules in the suffix where the prefix implies it cannot be
    // unsplit.
    traverseImplied(Rule rule) {
      if (suffix.contains(rule)) implied.add(rule);
      rule.implies.forEach(traverseImplied);
    }

    for (var rule in prefix) {
      var ruleValue = rule == nextRule ? value : ruleValues[rule];
      if (ruleValue != null && ruleValue != 0) traverseImplied(rule);
    }

    // Fill in the pinned rule values for the rules that appear in the suffix
    // that we have values for, including the rule for the next chunk.
    for (var rule in prefix) {
      if (!suffix.contains(rule)) continue;

      updatedRules[rule] = rule == nextRule ? value : ruleValues[rule];
    }
  }
}
