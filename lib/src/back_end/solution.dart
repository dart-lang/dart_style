// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../piece/piece.dart';
import '../profile.dart';
import 'code_writer.dart';
import 'solution_cache.dart';

/// A single possible set of formatting choices.
///
/// Each solution binds some number of [Piece]s in the piece tree to [State]s.
/// (Any pieces whose states are not bound are treated as having a default
/// unsplit state.)
///
/// Given that set of states, we can create a [CodeWriter] and give that to all
/// of the pieces in the tree so they can format themselves. That in turn
/// yields a total number of overflow characters, cost, and formatted output,
/// which are all stored here.
class Solution implements Comparable<Solution> {
  /// The states that pieces have been bound to.
  ///
  /// Note that order that keys are inserted into this map is significant. When
  /// ordering solutions, we use the order that pieces are bound in here to
  /// break ties between solutions that otherwise have the same cost and
  /// overflow.
  final Map<Piece, State> _pieceStates;

  /// The set of states that pieces are allowed to be in without violating
  /// constraints of already bound pieces.
  ///
  /// Each key is a constrained piece and the values are the remaining states
  /// that the piece may take which aren't known to violate existing
  /// constraints. If a piece is not in this map, then there are no constraints
  /// on it.
  final Map<Piece, List<State>> _allowedStates;

  /// The amount of penalties applied based on the chosen line splits.
  int get cost => _cost;
  int _cost;

  /// The formatted code.
  String get text => _text;
  late final String _text;

  /// False if this Solution contains a newline where one is prohibited.
  ///
  /// An invalid solution may have no overflow characters and the lowest score,
  /// but is still considered worse than any other valid solution.
  bool get isValid => _isValid;
  bool _isValid = true;

  /// Whether the solution contains an invalid newline and the piece that
  /// prohibits the newline is bound in this solution.
  ///
  /// When this is `true`, it means this solution and every solution that could
  /// be derived from it is invalid so the whole solution tree can be discarded.
  bool _isDeadEnd = false;

  /// The total number of characters that do not fit inside the page width.
  int get overflow => _overflow;
  int _overflow = 0;

  /// The unsolved piece in this solution that should be expanded next to
  /// produce new more refined solutions, if there is one.
  ///
  /// The tree of possible solutions is combinatorial in the number of pieces
  /// and exponential in the number of states those pieces can take. We can't
  /// afford to brute force explore the whole tree, even with the optimization
  /// that we stop as soon as we find a solution with no overflow.
  ///
  /// Most possible solutions add unnecessary splits in regions of the code
  /// that already fit within the page width. Exploring those is wasted time.
  /// To avoid that, we rely on a couple of insights:
  ///
  /// First, the solver treats any piece with an unselected state as being
  /// unsplit. This means that refining a solution always takes a piece that is
  /// unsplit and makes it split more. That monotonically increases the cost,
  /// but may help fit the solution inside the page.
  ///
  /// Therefore, we don't want to select states for most pieces. Only pieces
  /// that need to split in order to find a solution that fits in the page
  /// width or that are necessary because the unsplit state is invalid. (The
  /// latter usually means a line comment or statement occurs inside the piece.)
  ///
  /// So we skip past any pieces that aren't on overflowing lines or on lines
  /// whose newline led to an invalid solution. Further, it's also the case
  /// that splitting earlier pieces will often reshuffle the formatting of much
  /// of the code following it.
  ///
  /// Thus we only worry about unsolved pieces on the *first* problematic line
  /// when expanding. If selecting states for those pieces still doesn't help,
  /// the solver will work its way through later pieces from those subsequent
  /// partial solutions.
  ///
  /// This lets us efficiently skip through almost all of the pieces that don't
  /// need to be touched in order to find a valid solution.
  ///
  /// If this is empty, then there are no further solutions to generate from
  /// this one. It's either a dead end or a winner.
  late final List<Piece> _expandPieces;

  /// The offset in [text] where the selection starts, or `null` if there is
  /// no selection.
  int? get selectionStart => _selectionStart;
  int? _selectionStart;

  /// The offset in [text] where the selection ends, or `null` if there is
  /// no selection.
  int? get selectionEnd => _selectionEnd;
  int? _selectionEnd;

  /// Creates a new [Solution] with no pieces set to any state (which
  /// implicitly means they have state [State.unsplit] unless they're pinned to
  /// another state).
  factory Solution(SolutionCache cache, Piece root,
      {required int pageWidth, required int leadingIndent, State? rootState}) {
    var solution =
        Solution._(cache, root, pageWidth, leadingIndent, 0, {}, {}, rootState);
    solution._format(cache, root, pageWidth, leadingIndent);
    return solution;
  }

  Solution._(SolutionCache cache, Piece root, int pageWidth, int leadingIndent,
      this._cost, this._pieceStates, this._allowedStates,
      [State? rootState]) {
    Profile.count('create Solution');

    // If we're formatting a subtree of a larger Piece tree that binds [root]
    // to [rootState], then bind it in this solution too.
    if (rootState != null) _bind(root, rootState);
  }

  /// Attempt to eagerly bind [piece] to a state given that it must fit within
  /// [pageWidth] (which is the overall page width minus any leading indentation
  /// in the solution where this is called).
  ///
  /// If it can, binds the piece to that state in this solution and returns
  /// `true`. Otherwise returns `false`.
  bool tryBindByPageWidth(Piece piece, int pageWidth) {
    if (piece.fixedStateForPageWidth(pageWidth) case var state?) {
      _bind(piece, state);
      return true;
    }

    return false;
  }

  /// The state that [piece] is pinned to or that this solution selects.
  ///
  /// If no state has been selected, defaults to the first state.
  State pieceState(Piece piece) => pieceStateIfBound(piece) ?? State.unsplit;

  /// The state that [piece] is pinned to or that this solution selects.
  ///
  /// If no state has been selected, returns `null`.
  State? pieceStateIfBound(Piece piece) =>
      piece.pinnedState ?? _pieceStates[piece];

  /// Whether [piece] has been bound to a state in this set (or is pinned).
  bool isBound(Piece piece) =>
      piece.pinnedState != null || _pieceStates.containsKey(piece);

  /// Increases the total overflow for this solution by [overflow].
  ///
  /// This should only be called by [CodeWriter].
  void addOverflow(int overflow) {
    _overflow += overflow;
  }

  /// Apply the overflow, cost, and bound states from [subtreeSolution] to this
  /// solution.
  ///
  /// This is called when a subtree of a Piece tree is solved separately and
  /// the resulting solution is being merged with this one.
  void mergeSubtree(Solution subtreeSolution) {
    Profile.begin('Solution.mergeSubtree()');

    _overflow += subtreeSolution._overflow;

    // Add the subtree's bound pieces to this one. Make sure to not double
    // count costs for pieces that are already bound in this one.
    subtreeSolution._pieceStates.forEach((piece, state) {
      _pieceStates.putIfAbsent(piece, () {
        _cost += piece.stateCost(state);
        return state;
      });
    });

    Profile.end('Solution.mergeSubtree()');
  }

  /// Sets [selectionStart] to be [start] code units into the output.
  ///
  /// This should only be called by [CodeWriter].
  void startSelection(int start) {
    assert(_selectionStart == null);
    _selectionStart = start;
  }

  /// Sets [selectionEnd] to be [end] code units into the output.
  ///
  /// This should only be called by [CodeWriter].
  void endSelection(int end) {
    assert(_selectionEnd == null);
    _selectionEnd = end;
  }

  /// Mark this solution as having a newline where none is permitted by [piece]
  /// and is thus not a valid solution.
  ///
  /// This should only be called by [CodeWriter].
  void invalidate(Piece piece) {
    _isValid = false;

    // If the piece whose newline constraint was violated is already bound to
    // one state, then every solution derived from this one will also fail.
    if (!_isDeadEnd && isBound(piece)) _isDeadEnd = true;
  }

  /// Derives new potential solutions from this one by binding [_expandPieces]
  /// to all of their possible states.
  ///
  /// If there is no potential piece to expand, or all attempts to expand it
  /// fail, returns an empty list.
  List<Solution> expand(SolutionCache cache, Piece root,
      {required int pageWidth, required int leadingIndent}) {
    // If there is no piece that we can expand on this solution, it's a dead
    // end (or a winner).
    if (_expandPieces.isEmpty) return const [];

    var solutions = <Solution>[];
    for (var i = 0; i < _expandPieces.length; i++) {
      // For each non-default state that the expanding piece can be in, create
      // a new solution that inherits all of the bindings of this one, and binds
      // the expanding piece to that state (along with any further pieces
      // constrained by that one).
      var expandPiece = _expandPieces[i];
      for (var state
          in _allowedStates[expandPiece] ?? expandPiece.additionalStates) {
        var expanded = Solution._(cache, root, pageWidth, leadingIndent, cost,
            {..._pieceStates}, {..._allowedStates});

        // Bind all preceding expand pieces to their unsplit state. Their
        // other states have already been expanded by earlier iterations of
        // the outer for loop.
        var valid = true;
        for (var j = 0; j < i; j++) {
          expanded._bind(_expandPieces[j], State.unsplit);

          if (expanded._isDeadEnd) {
            valid = false;
            break;
          }
        }

        // Discard the solution if we hit a constraint violation.
        if (!valid) continue;

        expanded._bind(expandPiece, state);

        // Discard the solution if we hit a constraint violation.
        if (!expanded._isDeadEnd) {
          expanded._format(cache, root, pageWidth, leadingIndent);

          // TODO(rnystrom): These come mostly (entirely?) from hard newlines
          // in sequences, comments, and multiline strings. It should be
          // possible to handle those during piece construction too. If we do,
          // remove this check.
          // We may not detect some newline violations until formatting.
          if (!expanded._isDeadEnd) solutions.add(expanded);
        }
      }
    }

    return solutions;
  }

  /// Compares two solutions where a more desirable solution comes first.
  ///
  /// For performance, we want to stop checking solutions as soon as we find
  /// the best one. Best means the fewest overflow characters and the lowest
  /// code.
  @override
  int compareTo(Solution other) {
    // Even though overflow is "worse" than cost, we order in terms of cost
    // because a solution with overflow may lead to a low-cost solution without
    // overflow, so we want to explore in cost order.
    if (cost != other.cost) return cost.compareTo(other.cost);

    if (overflow != other.overflow) return overflow.compareTo(other.overflow);

    // If all else is equal, prefer lower states in earlier bound pieces.
    for (var piece in _pieceStates.keys) {
      var thisState = pieceState(piece);
      var otherState = other.pieceState(piece);
      if (thisState != otherState) return thisState.compareTo(otherState);
    }

    return 0;
  }

  @override
  String toString() {
    var states = [
      for (var MapEntry(key: piece, value: state) in _pieceStates.entries)
        if (piece.additionalStates.isNotEmpty && piece.pinnedState == null)
          '$piece$state'
    ];

    return [
      '\$$cost',
      if (overflow > 0) '($overflow over)',
      if (!isValid) '(invalid)',
      states.join(' '),
    ].join(' ').trim();
  }

  /// Run a [CodeWriter] on this solution to produce the final formatted output
  /// and calculate the overflow and expand pieces.
  void _format(
      SolutionCache cache, Piece root, int pageWidth, int leadingIndent) {
    var writer = CodeWriter(pageWidth, leadingIndent, cache, this);
    writer.format(root);
    var (text, expandPieces) = writer.finish();

    _text = text;
    _expandPieces = expandPieces;
  }

  /// Attempts to add a binding from [piece] to [state] to the solution, and
  /// then adds any further bindings from constraints that [piece] applies to
  /// its children, recursively.
  ///
  /// This may invalidate the solution if [piece] is already bound to a
  /// different [state], or if any constrained pieces are bound to different
  /// states.
  ///
  /// If successful, adds the cost required to bind [piece] to [state] (along
  /// with any other applied constrained pieces). Otherwise, marks the solution
  /// as a dead end.
  void _bind(Piece piece, State state) {
    // If we've already failed from a previous violation, early out.
    if (_isDeadEnd) return;

    // Apply the new binding if it doesn't conflict with an existing one.
    switch (pieceStateIfBound(piece)) {
      case null:
        // Binding a unbound piece to a state.
        _cost += piece.stateCost(state);
        _pieceStates[piece] = state;

        // This piece may in turn place further constraints on others.
        piece.applyConstraints(state, _bind);

        // If this piece's state prevents some of its children from having
        // newlines, then further constrain those children.
        if (!_isDeadEnd) {
          piece.forEachChild((child) {
            // Stop as soon as we fail.
            if (_isDeadEnd) return;

            // If the child can have newlines, there is no constraint.
            if (piece.allowNewlineInChild(state, child)) return;

            // Otherwise, don't let any piece under [child] contain newlines.
            _constrainOffspring(child);
          });
        }

      case var alreadyBound when alreadyBound != state:
        // Already bound to a different state, so there's a conflict.
        _isDeadEnd = true;
        _isValid = false;

      default:
        break; // Already bound to the same state, so nothing to do.
    }
  }

  /// For [piece] and its transitive offspring subtree, eliminate any state that
  /// will always produce a newline since that state is not permitted because
  /// the parent of [piece] doesn't allow [piece] to have any newlines.
  void _constrainOffspring(Piece piece) {
    for (var offspring in piece.statefulOffspring) {
      if (_isDeadEnd) break;

      if (pieceStateIfBound(offspring) case var boundState?) {
        // This offspring is already pinned or bound to a state. If that
        // state will emit newlines, then this solution is invalid.
        if (offspring.containsNewline(boundState)) {
          _isDeadEnd = true;
          _isValid = false;
        }
      } else if (!_allowedStates.containsKey(offspring)) {
        // If we get here, the offspring isn't bound to a state and we haven't
        // already constrained it. Eliminate any of its states that will emit
        // newlines.
        var allowedUnsplit = !offspring.containsNewline(State.unsplit);

        var states = offspring.additionalStates;
        var remainingStates = <State>[];
        for (var state in states) {
          if (!offspring.containsNewline(state)) {
            remainingStates.add(state);
          }
        }

        if (!allowedUnsplit && remainingStates.isEmpty) {
          // There is no state this child can take that won't emit newlines,
          // and it's not allowed to, so this solution is bad.
          _isDeadEnd = true;
          _isValid = false;
        } else if (remainingStates.isEmpty) {
          // The only valid state is unsplit so bind it to that.
          _bind(offspring, State.unsplit);
        } else if (!allowedUnsplit && remainingStates.length == 1) {
          // There's only one valid state, so bind it to that.
          _bind(offspring, remainingStates.first);
        } else if (remainingStates.length < states.length) {
          // There are some constrained states, so keep the remaining ones.
          _allowedStates[offspring] = remainingStates;
        }
      }
    }
  }
}
