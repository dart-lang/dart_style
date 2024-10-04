// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A region of text selected by an optional start and end index, measured in
/// UTF-16 code units.
abstract base class Selection {
  /// The chunk of text.
  String get text;

  /// The offset from the beginning of [text] where the selection starts, or
  /// `null` if the selection does not start within this chunk.
  int? get selectionStart => _selectionStart;
  int? _selectionStart;

  /// The offset from the beginning of [text] where the selection ends, or
  /// `null` if the selection does not start within this chunk.
  int? get selectionEnd => _selectionEnd;
  int? _selectionEnd;

  /// Sets [selectionStart] to be [start] code units into [text].
  void startSelection(int start) {
    _selectionStart = start;
  }

  /// Sets [selectionStart] to be [fromEnd] code units from the end of [text].
  void startSelectionFromEnd(int fromEnd) {
    _selectionStart = text.length - fromEnd;
  }

  /// Sets [selectionEnd] to be [end] code units into [text].
  void endSelection(int end) {
    _selectionEnd = end;
  }

  /// Sets [selectionEnd] to be [fromEnd] code units from the end of [text].
  void endSelectionFromEnd(int fromEnd) {
    _selectionEnd = text.length - fromEnd;
  }
}
