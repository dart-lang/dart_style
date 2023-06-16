// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'fast_hash.dart';
import 'line_splitting/rule_set.dart';
import 'rule/rule.dart';

/// A single level of expression nesting.
///
/// When a line is split in the middle of an expression, this tracks the
/// context of where in the expression that split occurs. It ensures that the
/// [LineSplitter] obeys the expression nesting when deciding what column to
/// start lines at when split inside an expression.
///
/// Each instance of this represents a single level of expression nesting. If we
/// split at to chunks with different levels of nesting, the splitter ensures
/// they each get assigned to different columns.
///
/// In addition, each level has an indent. This is the number of spaces it is
/// indented relative to the outer expression. It's almost always
/// [Indent.expression], but cascades are special magic snowflakes and use
/// [Indent.cascade].
class NestingLevel extends FastHash {
  /// The nesting level surrounding this one, or `null` if this is represents
  /// top level code in a block.
  final NestingLevel? parent;

  /// The number of characters that this nesting level is indented relative to
  /// the containing level.
  ///
  /// Normally, this is [Indent.expression], but cascades use [Indent.cascade].
  final int indent;

  /// If this nesting level's depth should be controlled by a rule, this is the
  /// rule.
  ///
  /// This is used for argument lists so that whether or not the arguments are
  /// indented can be determined based on the rule's value.
  final Rule? _rule;

  /// The total number of characters of indentation from this level and all of
  /// its parents, after determining which nesting levels are actually used.
  ///
  /// This is only valid during line splitting.
  int get totalUsedIndent => _totalUsedIndent!;
  int? _totalUsedIndent;

  bool get isNested => parent != null;

  final String _debugName;

  NestingLevel()
      : parent = null,
        indent = 0,
        _rule = null,
        _debugName = '';

  NestingLevel._(this.parent, this.indent, this._rule, this._debugName);

  /// Creates a new deeper level of nesting indented [spaces] more characters
  /// that the outer level.
  NestingLevel nest(int spaces, Rule? rule, String debugName) =>
      NestingLevel._(this, spaces, rule, debugName);

  /// Clears the previously calculated total indent of this nesting level.
  void clearTotalUsedIndent() {
    _totalUsedIndent = null;
    parent?.clearTotalUsedIndent();
  }

  /// Calculates the total amount of indentation from this nesting level and
  /// all of its parents assuming only [usedNesting] levels are in use.
  void refreshTotalUsedIndent(
      Set<NestingLevel> usedNesting, RuleSet ruleValues) {
    var totalIndent = _totalUsedIndent;
    if (totalIndent != null) return;

    totalIndent = 0;

    if (parent != null) {
      parent!.refreshTotalUsedIndent(usedNesting, ruleValues);
      totalIndent += parent!.totalUsedIndent;
    }

    var isUsed = usedNesting.contains(this);

    // If the nesting level is associated with a rule, let the rule determine
    // the nesting based on its value. Otherwise, use the level's own nesting.
    //
    // In rare cases (like nested argument lists inside interpolation), it's
    // possible for a nesting level to be bound to a rule that isn't actually
    // used by any chunk. In that case, fall back to the nesting level's
    // indent.
    if (_rule case var rule? when rule.index != null) {
      // The nesting level is associated with a rule, so let the rule determine
      // the nesting.
      totalIndent +=
          rule.nestingIndent(isUsed: isUsed, ruleValues.getValue(rule));
    } else if (isUsed) {
      totalIndent += indent;
    }

    _totalUsedIndent = totalIndent;
  }

  @override
  String toString([Set<NestingLevel>? usedNesting]) {
    var name = _rule?.toString() ?? _debugName;
    var result = '$name$indent';
    if (usedNesting != null && !usedNesting.contains(this)) {
      result = '${name}_';
    }

    if (parent != null) {
      result = '${parent!.toString(usedNesting)}:$result';
    }

    return result;
  }
}
