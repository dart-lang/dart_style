import 'package:analyzer/dart/ast/token.dart';
import 'package:pub_semver/pub_semver.dart';

import '../ast_extensions.dart';
import '../dart_formatter.dart';

/// The formatting style that should be applied to code.
///
/// This is sort of the internal version of [DartFormatter]. The former is
/// public API so is limited in what it exposes. This contains getters for
/// internal use to determine what style rules to apply.
///
/// This also tracks how language version affects the style rules. From Dart 3.7
/// and forward, most changes to the formatting style are language versioned:
/// code whose language version is older than a style change will retain the
/// older style.
final class FormattingStyle {
  /// The [DartFormatter] the style was created from.
  final DartFormatter _formatter;

  /// The language version of the style.
  ///
  /// Usually the same version as [formatter], but may be different if the file
  /// being formatted has an `@dart=` comment.
  final Version _languageVersion;

  /// The number of characters allowed in a single line.
  ///
  /// Usually the same as [formatter]'s but may be different if the file being
  /// formatted has a `// dart format width = ` comment.
  final int pageWidth;

  FormattingStyle(this._formatter, {Version? languageVersion, int? pageWidth})
    : _languageVersion = languageVersion ?? _formatter.languageVersion,
      pageWidth = pageWidth ?? _formatter.pageWidth;

  String? get lineEnding => _formatter.lineEnding;

  /// The number of characters of indentation to prefix the output lines with.
  int get leadingIndent => _formatter.indent;

  /// Whether the code being formatted is at language version 3.7 and doesn't
  /// include the sweeping style changes in 3.8.
  bool get is3Dot7 => _languageVersion == Version(3, 7, 0);

  /// Whether a trailing comma should be preserved after for-loop updaters.
  bool get preserveTrailingCommaAfterForUpdaters =>
      _formatter.trailingCommas == TrailingCommas.preserve;

  /// Whether a trailing comma should be preserved after enum values.
  bool get preserveTrailingCommaAfterEnumValues =>
      _formatter.trailingCommas == TrailingCommas.preserve &&
      _languageVersion >= Version(3, 10, 0);

  /// Whether there is a trailing comma at the end of the list delimited by
  /// [rightBracket] which should be preserved by this style.
  bool preserveTrailingCommaBefore(Token rightBracket) =>
      _formatter.trailingCommas == TrailingCommas.preserve &&
      rightBracket.hasCommaBefore;
}
