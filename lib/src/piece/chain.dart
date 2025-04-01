// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import '../back_end/code_writer.dart';
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
final class ChainPiece extends Piece {
  /// Allow newlines in the last (or next-to-last) call but nowhere else.
  static const State _blockFormatTrailingCall = State(1, cost: 0);

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

  /// How to indent the chain when it splits.
  ///
  /// This is [Indent.expression] for regular chains or [Indent.cascade]
  /// for cascades.
  final Indent _indent;

  final bool _isCascade;

  /// Creates a new ChainPiece.
  ///
  /// Instead of calling this directly, prefer using [ChainBuilder].
  ChainPiece(
    this._target,
    this._calls, {
    required bool cascade,
    int leadingProperties = 0,
    int blockCallIndex = -1,
    Indent indent = Indent.expression,
  }) : _leadingProperties = leadingProperties,
       _blockCallIndex = blockCallIndex,
       _indent = indent,
       _isCascade = cascade,
       // If there are no calls, we shouldn't have created a chain.
       assert(_calls.isNotEmpty);

  @override
  List<State> get additionalStates => [
    if (_blockCallIndex != -1) _blockFormatTrailingCall,
    if (_leadingProperties > 0) _splitAfterProperties,
    State.split,
  ];

  @override
  int stateCost(State state) {
    if (state == State.split) {
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
      if (_isCascade) return 0;

      // If the chain is only properties, try to keep them together. Prefers:
      //
      //     variable =
      //         target.property.another;
      //
      // Over:
      //
      //     variable = target
      //         .property
      //         .another;
      if (_leadingProperties == _calls.length) return 2;
    }

    return super.stateCost(state);
  }

  @override
  Set<Shape> allowedChildShapes(State state, Piece child) {
    if (child == _target) {
      return switch (state) {
        // If the chain itself isn't fully split, only allow block splitting
        // in the target.
        State.unsplit ||
        _blockFormatTrailingCall ||
        _splitAfterProperties => const {Shape.inline, Shape.block},
        _ => Shape.all,
      };
    } else {
      switch (state) {
        case State.unsplit:
          return Shape.onlyInline;

        case _splitAfterProperties:
          // Don't allow splitting inside the properties.
          for (var i = 0; i < _leadingProperties; i++) {
            if (_calls[i]._call == child) return Shape.onlyInline;
          }

        case _blockFormatTrailingCall:
          return Shape.anyIf(_calls[_blockCallIndex]._call == child);
      }

      return Shape.all;
    }
  }

  @override
  void format(CodeWriter writer, State state) {
    switch (state) {
      case State.unsplit:
        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          writer.format(_calls[i]._call);
        }

      case _splitAfterProperties:
        writer.pushIndent(_indent);
        writer.setShapeMode(ShapeMode.beforeHeadline);
        writer.format(_target);

        for (var i = 0; i < _leadingProperties; i++) {
          writer.format(_calls[i]._call);
        }

        writer.setShapeMode(ShapeMode.afterHeadline);

        for (var i = _leadingProperties; i < _calls.length; i++) {
          writer.newline();

          // Every non-property call except the last will be on its own line.
          writer.format(_calls[i]._call, separate: i < _calls.length - 1);
        }

        writer.popIndent();

      case _blockFormatTrailingCall:
        // Don't treat a cascade as block-shaped in the surrounding context
        // even if it block splits. Prefer:
        //
        //     variable = target
        //       ..cascade(argument);
        //
        // Over:
        //
        //     variable = target..cascade(
        //       argument,
        //     );
        //
        // Note how the former makes it clearer that `variable` will be assigned
        // the value `target` and that the cascade is a secondary side-effect.
        if (_isCascade) writer.setShapeMode(ShapeMode.other);

        writer.format(_target);

        for (var i = 0; i < _calls.length; i++) {
          writer.format(_calls[i]._call);
        }

      case State.split:
        writer.pushIndent(_indent);
        writer.setShapeMode(ShapeMode.beforeHeadline);
        writer.format(_target);
        writer.setShapeMode(ShapeMode.afterHeadline);

        for (var i = 0; i < _calls.length; i++) {
          writer.newline();

          // The chain is fully split so every call except for the last is on
          // its own line.
          writer.format(_calls[i]._call, separate: i < _calls.length - 1);
        }

        writer.popIndent();
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
final class ChainCall {
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
