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
  static final _version3Dot7 = Version(3, 7, 0);
  static final _version3Dot10 = Version(3, 10, 0);
  static final _version3Dot13 = Version(3, 13, 0);

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
  bool get is3Dot7 => _languageVersion == _version3Dot7;

  /// Whether a trailing comma should be preserved after for-loop updaters.
  bool get preserveTrailingCommaAfterForUpdaters =>
      _formatter.trailingCommas == TrailingCommas.preserve;

  /// Whether a trailing comma should be preserved after enum values.
  bool get preserveTrailingCommaAfterEnumValues =>
      _formatter.trailingCommas == TrailingCommas.preserve &&
      _languageVersion >= _version3Dot10;

  /// Whether the formatter should penalize splitting in the target of a call
  /// chain if the target is an argument list with only one argument or a
  /// collection literal with only one element.
  bool get avoidSplittingSingleElementCallChainTargets =>
      _languageVersion >= _version3Dot13;

  /// Whether mixin declarations and extension types with brace bodies should
  /// always get a blank line above and below them.
  ///
  /// They always should have, but they were overlooked. We already do this for
  /// classes, enums, and extensions.
  bool get blankLineAroundMixinAndExtensionTypes =>
      _languageVersion >= _version3Dot13;

  /// Whether parameter lists should be block formatted in things like typedefs.
  bool get blockFormatParameterLists => _languageVersion >= _version3Dot13;

  /// Whether the LHS of an `as`, `is`, or `is!` expression can be block
  /// formatted.
  bool get blockFormatTypeTest => _languageVersion >= _version3Dot13;

  /// Whether an if-case pattern can be block-formatted when there is a guard
  /// clause as well.
  bool get blockFormatIfCaseWithGuard => _languageVersion < _version3Dot13;

  /// Whether the formatter should prefer overflow from "soft" characters versus
  /// others when no solution fits the page width and an overflowing solution
  /// must be chosen.
  ///
  /// Sometimes the formatter does it's best, but no solution fits in the page
  /// width. Usually, this is because the code has some long string literals or
  /// comments that the user should split manually. If the formatter treats all
  /// overflowing characters uniformly, then it will try to pick a solution that
  /// minimizes those overhanging strings and comments at the expense of
  /// choosing weird formatting for other code. In particularly bad cases, the
  /// strings or comments end up completely fitting and some other code runs
  /// over. When that happens, it's confusing to the user because it looks like
  /// the formatter just picked a weird solution for no reason. They don't see
  /// that the strings or comments were the problem.
  ///
  /// What we want is for the formatter to leave those strings or comments
  /// hanging past the page width so it's clear to the user where they need to
  /// split things to get everything to fit. Also, this minimizes the format
  /// churn when they do fix those strings or comments.
  ///
  /// To do that, the formatter distinguishes "soft" characters from other
  /// kinds of code. "Soft" code is string literals, comments, or a few other
  /// things that often follow a string literal or comment: `,`, `;`, or `() {`
  /// (including `async` or other modifiers that can appear in a function
  /// header) for a trailing block-formatted lambda. When an overflowing line of
  /// code ends in soft characters, the overflow cost of all of those characters
  /// is collapsed to a single point of penalty instead of one per character.
  /// (We don't go all the way to zero because it is still overflow and we still
  /// want to avoid it completely if possible.)
  ///
  /// That leads the formatter to prefer solutions where the overflow is mostly
  /// strings or comments, which is likely where the user needs to take action.
  /// This feature is only a heuristic and doesn't always highlight the reason
  /// no solution fits, but it's fairly simple one and does the right thing in
  /// common cases.
  ///
  /// This feature has no effect on code that does fit in the page width.
  bool get useSoftOverflow => _languageVersion >= _version3Dot13;

  /// Whether to force a blank line between imports and exports whose URIs are
  /// different categories: `dart:`, `package:`, or relative.
  bool get separateDirectiveSections => _languageVersion >= _version3Dot13;

  /// Whether to try to figure out a piece's state based on the page width
  /// before running the solver or during.
  ///
  /// Initially, this ran during solving but that leads to some subtle bugs in
  /// the solver. Performing it before solving is less effective for performance
  /// but avoids those bugs.
  ///
  /// We language version this even though the old logic was never correct to
  /// minimize unexpected churn.
  bool get pinStateByPageWidthBeforeSolving =>
      _languageVersion >= _version3Dot13;

  /// Whether an extension type's representation clause allows a trailing
  /// comma.
  ///
  /// When primary constructors were added in Dart 3.13, the grammar was
  /// adjusted to define extension types in terms of them which also means that
  /// a trailing comma is now permitted.
  bool get allowTrailingCommaInRepresentationClause =>
      _languageVersion >= _version3Dot13;

  /// Whether there is a trailing comma at the end of the list delimited by
  /// [rightBracket] which should be preserved by this style.
  bool preserveTrailingCommaBefore(Token rightBracket) =>
      _formatter.trailingCommas == TrailingCommas.preserve &&
      rightBracket.hasCommaBefore;
}
