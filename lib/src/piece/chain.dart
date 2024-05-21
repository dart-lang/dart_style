// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
import '../constants.dart';
import 'piece.dart';

/// A dotted series of property access or method calls, like:
///
///     target.getter.method().another.method();
///
/// This piece handles splitting before the `.` and controlling which argument
/// lists in the method calls are allowed to contain newlines.
///
/// Chains can split in four ways:
///
/// [State.unsplit] The entire chain on one line:
///
///     target.getter.method().another.method();
///
/// [_blockFormatTrailingCall] Don't split before any `.`. Split the last (or
/// next-to-last if there is a hanging unsplittable call at the end) method
/// call in the chain like a block while leaving other calls unsplit, as in:
///
///     target.property.first(1).block(
///       argument,
///       argument,
///     );
///
/// [_splitAfterProperties] Split the call chain at each method call, but leave
/// the leading properties on the same line as the target. We allow leading
/// properties to remain unsplit while splitting the rest of the chain since
/// property accesses often feel "closer" to the target then the methods called
/// on it, as in:
///
///     motorcycle.wheels.front
///         .rotate();
///
/// [State.split] Split before every `.` and indent the chain, like:
///
///     target
///         .getter
///         .method(
///           argument,
///           argument,
///         )
///         .another
///         .method(
///           argument,
///           argument,
///         );
class ChainPiece extends Piece {
  /// Allow newlines in the last (or next-to-last) call but nowhere else.
  static const State _blockFormatTrailingCall = State(1, cost: 0);

  // TODO(tall): Currently, we only allow a single call in the chain to be
  // block-formatted, and it must be the last or next-to-last. That covers
  // the majority of common use cases (>90% of Flutter call chains), but there
  // are some cases (<1%) where it might be good to support multiple block
  // calls in a chain, like:
  //
  //     future.then((_) {
  //       doStuff();
  //     }).then((_) {
  //       moreStuff();
  //     }).catchError((error) {
  //       print('Oh no!');
  //     });
  //
  // Decide if we want to support this and, if so, which calls are allowed to
  // be block formatted. A reasonable approach would be to say that multiple
  // block calls are allowed when the chain is (possibly zero) leading
  // properties followed by only splittable calls and all splittable calls get
  // block formatted.

  /// Split the call chain at each method call, but leave the leading properties
  /// on the same line as the target.
  static const State _splitAfterProperties = State(2);

  /// The target expression at the beginning of the call chain.
  final Piece _target;

  /// The series of calls.
  ///
  /// The first piece in this is the target, and the rest are operations.
  final List<ChainCall> _calls;

  /// The number of contiguous calls at the beginning of the chain that are
  /// properties.
  final int _leadingProperties;

  /// The index of the call in the chain that may be block formatted or `-1` if
  /// none can.
  ///
  /// This will either be the index of the last call, or the index of the
  /// second to last call if the last call is a property or unsplittable call
  /// and the last call's argument list can be block formatted.
  final int _blockCallIndex;

  /// Whether the target expression may contain newlines when the chain is not
  /// fully split. (It may always contain newlines when the chain splits.)
  ///
  /// This is true for most expressions but false for delimited ones to avoid
  /// this weird output:
  ///
  ///     function(
  ///       argument,
  ///     )
  ///         .method();
  final bool _allowSplitInTarget;

  /// How much to indent the chain when it splits.
  ///
  /// This is [Indent.expression] for regular chains and [Indent.cascade] for
  /// cascades.
  final int _indent;

  final bool _isCascade;

  /// Creates a new ChainPiece.
  ///
  /// Instead of calling this directly, prefer using [ChainBuilder].
  ChainPiece(this._target, this._calls,
      {required bool cascade,
      int leadingProperties = 0,
      int blockCallIndex = -1,
      int indent = Indent.expression,
      required bool allowSplitInTarget})
      : _leadingProperties = leadingProperties,
        _blockCallIndex = blockCallIndex,
        _indent = indent,
        _allowSplitInTarget = allowSplitInTarget,
        _isCascade = cascade,
        // If there are no calls, we shouldn't have created a chain.
        assert(_calls.isNotEmpty);

  @override
  List<State> get additionalStates => [
        if (_blockCallIndex != -1) _blockFormatTrailingCall,
        if (_leadingProperties > 0) _splitAfterProperties,
        State.split
      ];

  @override
  int stateCost(State state) {
    // If the chain is a cascade, lower the cost so that we prefer splitting
    // the cascades instead of the target. Prefers:
    //
    //     [element1, element2]
    //       ..cascade();
    //
    // Over:
    //
    //     [
    //       element1,
    //       element2,
    //     ]..cascade();
    if (state == State.split) return _isCascade ? 0 : 1;

    return super.stateCost(state);
  }

  @override
  bool allowNewlineInChild(State state, Piece child) {
    switch (state) {
      case _ when child == _target:
        return _allowSplitInTarget || state == State.split;

      case State.unsplit:
        return false;

      case _splitAfterProperties:
        for (var i = 0; i < _leadingProperties; i++) {
          if (_calls[i]._call == child) return false;
        }

      case _blockFormatTrailingCall:
        return _calls[_blockCallIndex]._call == child;
    }

    return true;
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          _formatCall(writer, state, i, allowNewlines: false);
        }

      case _splitAfterProperties:
        writer.pushIndent(_indent);
        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          writer.splitIf(i >= _leadingProperties, space: false);
          _formatCall(writer, state, i, allowNewlines: i >= _leadingProperties);
        }

        writer.popIndent();

      case _blockFormatTrailingCall:
        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          _formatCall(writer, state, i, allowNewlines: i == _blockCallIndex);
        }

      case State.split:
        writer.pushIndent(_indent);
        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          writer.newline();
          _formatCall(writer, state, i);
        }

        writer.popIndent();
    }
  }

  void _formatCall(CodeWriter writer, State state, int i,
      {bool allowNewlines = true}) {
    // If the chain is fully split, then every call except for the last will
    // be on its own line. If the chain is split after properties, then
    // every non-property call except the last will be on its own line.
    var separate = switch (state) {
      _splitAfterProperties => i >= _leadingProperties && i < _calls.length - 1,
      State.split => i < _calls.length - 1,
      _ => false,
    };

    writer.format(_calls[i]._call, separate: separate);
  }

  @override
  void forEachChild(void Function(Piece piece) callback) {
    callback(_target);

    for (var call in _calls) {
      callback(call._call);
    }
  }
}

/// A method or getter call in a call chain, along with any postfix operations
/// applies to it.
class ChainCall {
  /// Piece for the call.
  Piece _call;

  final CallType type;

  ChainCall(this._call, this.type);

  bool get canSplit =>
      type == CallType.splittableCall || type == CallType.blockFormatCall;

  /// Applies a postfix operation to this call.
  ///
  /// Invokes [createPostfix] with the current piece for the call. That
  /// callback should return a new piece that contains [target] followed by the
  /// postfix operation.
  void wrapPostfix(Piece Function(Piece target) createPostfix) {
    _call = createPostfix(_call);
  }
}

/// What kind of "call" a dotted expression in a call chain is.
enum CallType {
  /// A property access, like `.foo`.
  property,

  /// A method call with an empty argument list that can't split.
  unsplittableCall,

  /// A method call with a non-empty argument list that can split but not
  /// block format.
  splittableCall,

  /// A method call with a non-empty argument list that can be block formatted.
  blockFormatCall,
}
