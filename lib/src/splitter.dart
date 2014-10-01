// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.splitter;

import 'line.dart';

/// A wrapper around a bit of state -- whether or not a set of [SplitChunks]
/// are active of not.
///
/// Each [SplitChunk] has a reference to the [SplitState] that controls it.
/// When the state is active, all of the split chunks will be applied, which
/// may in turn output line-breaks, indentation, unindentation, etc.
abstract class SplitState {
  /// Whether or not this splitter is currently in effect.
  ///
  /// If `false`, then the splitter is not trying to do any line splitting. If
  /// `true`, it is.
  bool get isSplit;
}

/// An actively configurable [SplitState].
///
/// When [LinePrinter] tries to split a line to fit within its page width, it
/// does so by trying different combinations of parameters to see which set of
/// active ones yields the best result.
///
/// Unlike [SplitState] which exposes only a read-only view of the current
/// state, this lets outside code (the line printer) actively modify the split
/// state.
class SplitParam implements SplitState {
  bool isSplit = false;
}

/// A [SplitState] whose state depends on others.
///
/// Unlike [SplitParam]s, which can be manually configured, the state of this is
/// implicit. It maintains references to other splits states. If any of them
/// are split, then this one is too.
///
/// This is used, for example, in a parameter list to ensure that if any of
/// the parameters are wrapped then the whole list is indented.
class AnySplitState implements SplitState {
  final states = <SplitState>[];

  bool get isSplit => states.any((splitter) => splitter.isSplit);
}

/// A strategy for splitting a line into one more separate lines.
///
/// Each instance of this controls one or more [SplitChunk]s in the [Line] and
/// exposes one or parameters that can be used to determine if they split or
/// not.
///
/// A splitter is also responsible for influencing how "good" a given set of
/// split states is. The line printer weighs the influences of all of the
/// splitters on the line to see how good a given set of choices is.
abstract class Splitter {
  /// The set of parameters that can be toggled to control this splitter.
  Iterable<SplitParam> get params;

  /// Returns `true` if this splitter's current parameters are valid given that
  /// its splits mapped to [splitLines].
  ///
  /// This lets a splitter do validation *after* all other splits have been
  /// applied. It allows things like list literals to base their splitting on
  /// how their contents ended up being split.
  bool isValid(List<int> splitLines) => true;
}

/// A [Splitter] for list literals.
class ListSplitter extends Splitter {
  final _param = new SplitParam();

  Iterable<SplitParam> get params => [_param];

  /// The split used after the "[".
  SplitChunk get openBracket => new SplitChunk(_param, this, indent: 1);

  /// The split used after the "," after each list item.
  SplitChunk get afterElement => new SplitChunk(_param, this, text: " ");

  /// The split used before the "]".
  SplitChunk get closeBracket => new SplitChunk(_param, this, indent: -1);

  // Ensures the list is always split into its multi-line form if its elements
  // do not all fit on one line.
  bool isValid(List<int> splitLines) {
    // Splitting is always allowed.
    if (_param.isSplit) return true;

    // TODO(rnystrom): Do we want to allow single-element lists to remain
    // unsplit if their contents split, like:
    //
    //     [[
    //       first,
    //       second
    //     ]]

    var line = splitLines.first;
    return splitLines.every((other) => other == line);
  }
}

/// A splitter for variable declaration initializers and assignments.
class AssignmentSplitter extends Splitter {
  final _param = new SplitParam();

  Iterable<SplitParam> get params => [_param];

  /// The split used after the "=".
  SplitChunk get equals => new SplitChunk(_param, this, text: " ", indent: 2);

  /// The split used after the RHS expression.
  SplitChunk get unindent => new SplitChunk(_param, this, indent: -2,
      isNewline: false);
}

/// A splitter for a list of variable declarations.
class DeclarationListSplitter extends Splitter {
  final _param = new SplitParam();

  Iterable<SplitParam> get params => [_param];

  /// The split used after the first variable.
  SplitChunk get indent =>
      new SplitChunk(_param, this, indent: 2, isNewline: false);

  /// The split used after the "," after each variable.
  SplitChunk get afterVariable => new SplitChunk(_param, this, text: " ");

  /// The split used after the last variable.
  SplitChunk get unindent =>
      new SplitChunk(_param, this, indent: -2, isNewline: false);
}

/// A splitter for a list of formal parameters or arguments.
class ParameterListSplitter extends Splitter {
  final params = <SplitParam>[];

  /// If any of the parameters get wrapped, the whole list needs to be
  /// indented.
  final _indentSplit = new AnySplitState();

  /// The split used to indent the parameter list if needed.
  SplitChunk get indent =>
      new SplitChunk(_indentSplit, this, indent: 2, isNewline: false);

  /// The split used after the "(" before the first parameter.
  /// a new [SplitParam] for it each time this is accessed.
  SplitChunk get beforeFirst => _beforeFirst;
  SplitChunk _beforeFirst;

  /// The split used after the last parameter.
  SplitChunk get unindent =>
      new SplitChunk(_indentSplit, this, indent: -2, isNewline: false);

  ParameterListSplitter() {
    var param = new SplitParam();
    params.add(param);
    _indentSplit.states.add(param);
    _beforeFirst = new SplitChunk(param, this);
  }

  /// A split used after the "(" or "," between parameters.
  ///
  /// Each variable can be split independently, so this creates a new one and
  /// a new [SplitParam] for it each time this is accessed.
  SplitChunk parameter() {
    var param = new SplitParam();
    params.add(param);
    _indentSplit.states.add(param);
    return new SplitChunk(param, this, text: " ");
  }
}
