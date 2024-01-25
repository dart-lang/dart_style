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
  /// second to last call if the last call is a property or unsplittable.
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

  /// Creates a new ChainPiece.
  ///
  /// Instead of calling this directly, prefer using [ChainBuilder].
  ChainPiece(this._target, this._calls,
      {int leadingProperties = 0,
      int blockCallIndex = -1,
      int indent = Indent.expression,
      required bool allowSplitInTarget})
      : _leadingProperties = leadingProperties,
        _blockCallIndex = blockCallIndex,
        _indent = indent,
        _allowSplitInTarget = allowSplitInTarget,
        // If there are no calls, we shouldn't have created a chain.
        assert(_calls.isNotEmpty);

  @override
  List<State> get additionalStates => [
        if (_blockCallIndex != -1) _blockFormatTrailingCall,
        if (_leadingProperties > 0) _splitAfterProperties,
        State.split
      ];

  @override
  void format(CodeWriter writer, State state) {
    // If we split at the ".", then indent all of the calls, like:
    //
    //     target
    //         .call(
    //           arg,
    //         );
    switch (state) {
      case State.unsplit:
        writer.setAllowNewlines(_allowSplitInTarget);
      case _splitAfterProperties:
        writer.setIndent(_indent);
        writer.setAllowNewlines(_allowSplitInTarget);
      case _blockFormatTrailingCall:
        writer.setAllowNewlines(_allowSplitInTarget);
      case State.split:
        writer.setIndent(_indent);
    }

    writer.format(_target);

    for (var i = 0; i < _calls.length; i++) {
      switch (state) {
        case State.unsplit:
          writer.setAllowNewlines(false);
        case _splitAfterProperties:
          writer.setAllowNewlines(i >= _leadingProperties);
          writer.splitIf(i >= _leadingProperties, space: false);
        case _blockFormatTrailingCall:
          writer.setAllowNewlines(i == _blockCallIndex);
        case State.split:
          writer.setAllowNewlines(true);
          writer.newline();
      }

      var call = _calls[i];
      writer.format(call._call);
    }
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

  bool get canSplit => type == CallType.splittableCall;

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

  /// A method call with a non-empty argument list that can split.
  splittableCall
}
