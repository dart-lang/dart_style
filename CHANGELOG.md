## 3.0.1

* Handle trailing commas in for-loop updaters (#1354).
* Format `||` patterns like fallthrough cases in switch expressions (#1602).
* Handle comments and metadata before variables more gracefully (#1604).
* Ensure comment formatting is idempotent (#1606).
* Better indentation of leading comments on property accesses in binary operator
  operands (#1611).
* Don't crash on doc comments in local variable declarations (#1621).

## 3.0.0

This is a large change. Under the hood, the formatter was almost completely
rewritten, with the codebase now containing both the old and new
implementations. The old formatter exists to support the older "short" style
and the new code implements [the new "tall" style][tall].

[tall]: https://github.com/dart-lang/dart_style/issues/1253

The formatter uses the language version of the formatted code to determine
which style you get. If the language version is 3.6 or lower, the code is
formatted with the old style. If 3.7 or later, you get the new tall style. You
typically control the language version by [setting a min SDK constraint in your
package's pubspec][versioning].

[versioning]: https://dart.dev/guides/language/evolution

In addition to the new formatting style, a number of other API and CLI changes
are included, some of them breaking:

* **Support project-wide page width configuration.** By long request, you can
  now configure your preferred formatting page width on a project-wide basis.
  When formatting files, the formatter will look in the file's directory and
  any surrounding directories for an `analysis_options.yaml` file. If it finds
  one, it looks for the following YAML:

  ```yaml
  formatter:
    page_width: 123
  ```

  If it finds a `formatter` key containing a map with a `page_width` key whose
  value is an integer, then that is the page width that the file is formatted
  using. Since the formatter will walk the surrounding directories until it
  finds an `analysis_options.yaml` file, this can be used to globally set the
  page width for an entire directory, package, or even collection of packages.

* **Support overriding the page width for a single file.** In code formatted
  using the new tall style, you can use a special marker comment to control the
  page width that it's formatted using:

  ```dart
  // dart format width=30
  main() {
    someExpression +
        thatSplitsAt30;
  }
  ```

  This comment must appear before any code in the file and must match that
  format exactly. The width set by the comment overrides the width set by any
  surrounding `analysis_options.yaml` file.

  This feature is mainly for code generators that generate and immediately
  format code but don't know about any surrounding `analysis_options.yaml`
  that might be configuring the page width. By inserting this comment in the
  generated code before formatting, it ensures that the code generator's
  behavior matches the behavior of `dart format`.

  End users should mostly use `analysis_options.yaml` for configuring their
  preferred page width (or do nothing and use the default page width of 80).

* **Support opting out a region of code from formatting.** In code formatted
  using the new tall style, you can use a pair of special marker comments to
  opt a region of code out of automated formatting:

  ```dart
  main() {
    this.isFormatted();
    // dart format off
    no   +   formatting
      +
        here;
    // dart format on
    formatting.isBackOnHere();
  }
  ```

  The comments must be exactly `// dart format off` and `// dart format on`.
  A file may have multiple regions, but they can't overlap or nest.

  This can be useful for highly structured data where custom layout can help
  a reader understand the data, like large lists of numbers.

* **Remove support for fixes and `--fix`.** The tools that come with the Dart
  SDK provide two ways to apply automated changes to code: `dart format --fix`
  and `dart fix`. The former is older and used to be faster. But it can only
  apply a few fixes and hasn't been maintained in many years. The `dart fix`
  command is actively maintained, can apply all of the fixes that
  `dart format --fix` could apply and many many more.

  In order to avoid duplicate engineering effort, we decided to consolidate on
  `dart fix` as the one way to make automated changes that go beyond the simple
  formatting and style changes that `dart format` applies.

  The ability to apply fixes is also removed from the `DartFormatter()` library
  API.

* **Make the language version parameter to `DartFormatter()` mandatory.** This
  way, the formatter always knows what language version the input is intended
  to be treated as. Note that a `// @dart=` language version comment, if
  present, overrides the specified language version. You can think of the
  version passed to the `DartFormatter()` constructor as a "default" language
  version which the file's contents may then override.

  If you don't particularly care about the version of what you're formatting,
  you can pass in `DartFormatter.latestLanguageVersion` to unconditionally get
  the latest language version that the formatter supports. Note that doing so
  means you will also implicitly opt into the new tall style.

  This change only affects the library API. When using the formatter from the
  command line, you can use `--language-version=` to specify a language version
  or pass `--language-version=latest` to use the latest supported version. If
  omitted, the formatter will look in the surrounding directories for a package
  config file and infer the language version for the package from that, similar
  to how other Dart tools behave like `dart analyze` and `dart run`.

* **Remove the old formatter executables and CLI options.** Before the
  `dart format` command was added to the core Dart SDK, users accessed the
  formatter by running a separate `dartfmt` executable that was included with
  the Dart SDK. That executable had a different CLI interface. For example, you
  had to pass `-w` to get it to overwrite files. When we added `dart format`,
  we took that opportunity to revamp the CLI options.

  However, the dart_style package still exposed an executable with the old CLI.
  If you ran `dart pub global activate dart_style`, this would give you a
  `dartfmt` (and `dartformat`) executable with the old CLI options. Now that
  almost everyone is using `dart format`, we have removed the old CLI and the
  old package executables.

  You can still run the formatter on the CLI through the package (for example,
  if you want to use a particular version of dart_style instead of the one
  bundled with your Dart SDK). But it now uses the exact same CLI options and
  arguments as the `dart format` command. You can invoke it with
  `dart run dart_style:format <args...>`.

* **Treat the `--stdin-name` name as a path when inferring language version.**
  When reading input on stdin, the formatter still needs to know what language
  version to parse the code as. If the `--stdin-name` option is set, then that
  is treated as a file path and the formatter looks for a package config
  surrounding that file path to infer the language version from.

  If you don't want that behavior, pass in an explicit language version using
  `--language-version=`, or use `--language-version=latest` to parse the input
  using the latest language version supported by the formatter.

  If `--stdin-name` and `--language-version` are both omitted, then the
  formatter parses stdin using the latest supported language version.

* **Rename the `--line-length` option to `--page-width`.** This is consistent
  with the public API, internal implementation, and docs, which all use "page
  width" to refer to the limit that the formatter tries to fit code into.

  The `--line-length` name is still supported for backwards compatibility, but
  may be removed at some point in the future. You're encouraged to move to
  `--page-width`. Use of this option (however it's named) is rare, and will
  likely be even rarer now that project-wide configuration is supported, so
  this shouldn't affect many users.

* **Apply class modifiers to API classes.** The dart_style package exposes only
  a few classes in its public API: `DartFormatter`, `SourceCode`,
  `FormatterException`, and `UnexpectedOutputException`. None were ever
  intended to be extended or implemented. They are now all marked `final` to
  make that intention explicit.

* Require `package:analyzer` `>=6.5.0 <8.0.0`.

## 2.3.7

* Allow passing a language version to `DartFomatter()`. Formatted code will be
  parsed at that version. If omitted, defaults to the latest version. In a
  future release, this parameter will become required.
* Allow opting out of formatting for a region of code using `// dart format off`
  and `// dart format on` comments. Note: This only works using the new tall
  style and requires passing the `--enable-experiment=tall-style` experiment
  flag (#361).
* Preserve type parameters on old-style function-typed formals that also use
  `this.` or `super.` (#1321).
* Correctly format imports with both `as` and `if` clauses (#1544).
* Remove temporary work around for analyzer 6.2.0 from dart_style 2.3.6.
* Require `package:analyzer` `>=6.5.0 <7.0.0`.

## 2.3.6

* Fix compile error when using dart_style with analyzer 6.2.0.

## 2.3.5

* Ensure switch expressions containing line comments split (#1404).
* Use language version `3.3` to parse so that code with extension types can be
  formatted.
* Support formatting the `macro` modifier when the `macros` experiment flag
  is passed.

## 2.3.4

* Add `tall-style` experiment flag to enable the in-progress unstable new
  formatting style (#1253).
* Format extension types.
* Normalize ignored whitespace and "escaped whitespace" on first line
  of multiline string literals (#1235).

## 2.3.3

* Always split enum declarations containing a line comment (#1254).
* Fix regression in splitting type annotations with library prefixes (#1249).
* Remove support for `inline class` since that syntax has changed.
* Add `--enable-experiment` command-line option to enable language experiments.
  The library API also supports this with `DartFormatter.experimentFlags`.

## 2.3.2

* Don't indent parameters that have metadata annotations. Instead, align them
  with the metadata and other parameters.
* Allow metadata annotations on parameters to split independently of annotations
  on other parameters (#1212).
* Don't split before `.` following a record literal (#1213).
* Don't force split on a line comment before a switch expression case (#1215).
* Require `package:analyzer` `>=5.12.0 <7.0.0`.
* Preserve `?` on nullable empty record types (#1224).

## 2.3.1

* Hide `--fix` and related options in `--help`. The options are still there and
  supported, but are no longer shown by default. Eventually, we would like all
  users to move to using `dart fix` instead of `dart format --fix`.
* Don't indent `||` pattern operands in switch expression cases.
* Don't format `sealed`, `interface`, and `final` keywords on mixin
  declarations. The proposal was updated to no longer support them.
* Don't split before a single-section cascade following a record literal.
* Give records block-like formatting in argument lists (#1205).

## 2.3.0

### New language features

* Format patterns and related features.
* Format record expressions and record type annotations.
* Format class modifiers `base`, `final`, `interface`, `mixin`, and `sealed`.
* Format `inline class` declarations.
* Format unnamed libraries.

### Bug fixes and style changes

* Handle `sync*` and `async*` functions with `=>` bodies.
* Fix bug where parameter metadata wouldn't always split when it should.
* Don't split after `<` in collection literals.
* Better indentation of multiline function types inside type argument lists.

### Internal changes

* Use typed `_visitFunctionOrMethodDeclaration` instead of dynamically typed.
* Fix metadata test to not fail when record syntax makes whitespace between
  metadata annotation names and `(` significant ([sdk#50769][]).
* Require Dart 2.19.
* Require `package:analyzer` `^5.7.0`.

[sdk#50769]: https://github.com/dart-lang/sdk/issues/50769

## 2.2.5

* Format unnamed libraries.
* Require Dart 2.17.

## 2.2.4

* Unify how brace-delimited syntax is formatted. This is mostly an internal
  refactoring, but slightly changes how a type body containing only an inline
  block comment is formatted.
* Refactor Chunk to store split before text instead of after. This mostly does
  not affect the visible behavior of the formatter, but a few edge cases are
  handled slightly differently. These are all bug fixes where the previous
  behavior was unintentional. The changes are:
* Consistently discard blank lines between a `{` or `[` and a subsequent
  comment. It used to do this before the `{` in type bodies, but not switch
  bodies, optional parameter sections, or named parameter sections.
* Don't allow splitting an empty class body.
* Allow splitting after an inline block comment in some places where it makes
  sense.
* Don't allow a line comment in an argument list to cause preceding arguments
  to be misformatted.
* Remove blank lines after a line comment at the end of a body.
* Require `package:analyzer` `>=4.4.0 <6.0.0`.

## 2.2.3

* Allow the latest version of `package:analyzer`.

## 2.2.2

* Format named arguments anywhere (#1072).
* Format enhanced enums (#1075).
* Format "super." parameters (#1091).

## 2.2.1

* Require `package:analyzer` version `2.6.0`.
* Use `NamedType` instead of `TypeName`.

## 2.2.0

* Fix analyzer dependency constraint (#1051).

## 2.1.1

* Republish 2.0.3 as 2.1.1 in order to avoid users getting 2.1.0, which has a
  bad dependency constraint (#1051).

## 2.1.0

* Support generic function references and constructor tear-offs (#1028).

## 2.0.3

* Fix hang when reading from stdin (https://github.com/dart-lang/sdk/issues/46600).

## 2.0.2

* Don't unnecessarily split argument lists with `/* */` comments (#837).
* Return correct exit code from `FormatCommand` when formatting stdin (#1035).
* Always split cascades with multiple sections (#1006).
* Don't indent cascades farther than their receiver method chains.
* Optimize line splitting cascades (#811).
* Split empty catch blocks with finally clauses (#1029).
* Split empty catch blocks with catches after them.
* Allow the latest version of `package:analyzer`.

## 2.0.1

* Support triple-shift `>>>` and `>>>=` operators (#992).
* Support non-function type aliases (#993).
* Correct constructor initializer indentation after `required` (#1010).

## 2.0.0

* Migrate to null safety.

## 1.3.14

* Add support for generic annotations.
* `FormatCommand.run()` now returns the value set in `exitCode` during
  formatting.

## 1.3.13

- Allow the latest version of `package:analyzer`.

## 1.3.12

- Allow the latest versions of `package:args` and `package:pub_semver`.

## 1.3.11

* Remove use of deprecated analyzer API and List constructor.
* Fix performance issue with constructors that have no initializer list.

## 1.3.10

* Allow analyzer version 0.41.x.

## 1.3.9

* Don't duplicate comments on chained if elements (#966).

## 1.3.8

* Preserve `?` in initializing formal function-typed parameters (#960).

## 1.3.7

* Split help into verbose and non-verbose lists (#938).
* Don't crash when non-ASCII whitespace is trimmed (#901).
* Split all conditional expressions (`?:`) when they are nested (#927).
* Handle `external` and `abstract` fields and variables (#946).

## 1.3.6

* Change the path used in error messages when reading from stdin from "<stdin>"
  to "stdin". The former crashes on Windows since it is not a valid Windows
  pathname. To get the old behavior, pass `--stdin-name=<stdin>`.

## 1.3.5

* Restore command line output accidentally removed in 1.3.4.

## 1.3.4

* Add `--fix-single-cascade-statements`.
* Correctly handle `var` in `--fix-function-typedefs` (#826).
* Preserve leading indentation in fixed doc comments (#821).
* Split outer nested control flow elements (#869).
* Always place a blank line after script tags (#782).
* Don't add unneeded splits on if elements near comments (#888).
* Indent blocks in initializers of multiple-variable declarations.
* Update the null-aware subscript syntax from `?.[]` to `?[]`.

## 1.3.3

* Support `package:analyzer` `0.39.0`.

## 1.3.2

* Restore the code that publishes the dart-style npm package.
* Preserve comma after nullable function-typed parameters (#862).

## 1.3.1

* Fix crash in formatting complex method chains (#855).

## 1.3.0

* Add support for formatting extension methods (#830).
* Format `?` in types.
* Format the `late` modifier.
* Format the `required` modifier.
* Better formatting of empty spread collections (#831).
* Don't force split before `.` when the target is parenthesized (#704).

## 1.2.10

* Format null assertion operators.
* Better formatting for invocation expressions inside method call chains.
* Support `package:analyzer` `0.38.0`.

## 1.2.9

* Support `package:analyzer` `0.37.0`.

## 1.2.8

* Better indentation of function expressions inside trailing comma argument
  lists. (Thanks a14@!)
* Avoid needless indentation on chained if-else elements (#813).

## 1.2.7

* Improve indentation of adjacent strings inside `=>` functions.

## 1.2.6

* Properly format trailing commas in assertions.
* Improve indentation of adjacent strings. This fixes a regression introduced
  in 1.2.5 and hopefully makes adjacent strings generally look better.

  Adjacent strings in argument lists now format the same regardless of whether
  the argument list contains a trailing comma. The rule is that if the
  argument list contains no other strings, then the adjacent strings do not
  get extra indentation. This keeps them lined up when doing so is unlikely to
  be confused as showing separate independent string arguments.

  Previously, adjacent strings were never indented in argument lists without a
  trailing comma and always in argument lists that did. With this change,
  adjacent strings are still always indented in collection literals because
  readers are likely to interpret a series of unindented lines there as showing
  separate collection elements.

## 1.2.5

* Add support for spreads inside collections (#778).
* Add support for `if` and `for` elements inside collections (#779).
* Require at least Dart 2.1.0.
* Require analyzer 0.36.0.

## 1.2.4

* Update to latest analyzer package AST API.
* Tweak set literal formatting to follow other collection literals.

## 1.2.3

* Update `package:analyzer` constraint to `'>=0.33.0 <0.36.0'`.

## 1.2.2

* Support set literals (#751).

## 1.2.1

* Add `--fix-function-typedefs` to convert the old typedef syntax for function
  types to the new preferred syntax.

## 1.2.0

* Add `--stdin-name` to specify name shown when reading from stdin (#739).
* Add `--fix-doc-comments` to turn `/** ... */` doc comments into `///` (#730).
* Add support for new mixin syntax (#727).
* Remove `const` in all metadata annotations with --fix-optional-const` (#720).

## 1.1.4

* Internal changes to support using the new common front end for parsing.

## 1.1.3

* Preserve whitespace in multi-line strings inside string interpolations (#711).
  **Note!** This bug means that dart_style 1.1.2 may make semantics changes to
  your strings. You should avoid that version and use 1.1.3.

* Set max SDK version to <3.0.0, and adjusted other dependencies.

## 1.1.2

* Don't split inside string interpolations.

## 1.1.1

* Format expressions in string interpolations (#226).
* Apply fixes inside string interpolations (#707).

## 1.1.0

* Add support for "style fixes", opt-in non-whitespace changes.
* Add fix to convert `:` to `=` as the named parameter default value separator.
* Add fix to remove `new` keywords.
* Add fix to remove unneeded `const` keywords.
* Uniformly format constructor invocations and other static method calls.
* Don't crash when showing parse errors in Dart 2 mode (#697).

## 1.0.14

* Support metadata on enum cases (#688).

## 1.0.13

* Support the latest release of `package:analyzer`.

## 1.0.12

* Fix another failure when running in Dart 2.

## 1.0.11

* Fix cast failure when running in Dart 2.
* Updated SDK version to 2.0.0-dev.17.0.
* Force split in empty then block in if with an else (#680).

## 1.0.10

* Don't split before `.` if the target expression is an argument list with a
  trailing comma (#548, #665).
* Preserve metadata on for-in variables (#648).
* Support optional `new`/`const` (#652).
* Better formatting of initialization lists after trailing commas (#658).

## 1.0.9

* Updated tests. No user-facing changes.

## 1.0.8

* Support v1 of `pkg/args`.

## 1.0.7

* Format multiline strings as block arguments (#570).
* Fix call to analyzer API.
* Support assert in initializer list experimental syntax (#522).

## 1.0.6

* Support URIs in part-of directives (#615).

## 1.0.5

* Support the latest version of `pkg/analyzer`.

## 1.0.4

* Ensure formatter throws an exception instead of introducing non-whitespace
  changes. This sanity check ensures the formatter does not erase user code
  when the formatter itself contains a bug.
* Preserve type arguments in generic typedefs (#619).
* Preserve type arguments in function expression invocations (#621).

## 1.0.3

* Preserve type arguments in generic function-typed parameters (#613).

## 1.0.2

* Support new generic function typedef syntax (#563).

## 1.0.1

* Ensure space between `-` and `--` (#170).
* Preserve a blank line between enum cases (#606).

## 1.0.0

* Handle mixed block and arrow bodied function arguments uniformly (#500).
* Don't add a spurious space after "native" (#541).
* Handle parenthesized and immediately invoked functions in argument lists
  like other function literals (#566).
* Preserve a blank line between an annotation and the first directive (#571).
* Fix splitting in generic methods with `=>` bodies (#584).
* Allow splitting between a parameter name and type (#585).
* Don't split after `<` when a collection is in statement position (#589).
* Force a split if the cascade target has non-obvious precedence (#590).
* Split more often if a cascade target contains a split (#591).
* Correctly report unchanged formatting when reading from stdin.

## 0.2.16

* Don't discard type arguments on method calls with closure arguments (#582).

## 0.2.15

* Support `covariant` modifier on methods.

## 0.2.14

* Update to analyzer 0.29.3. This should make dart_style a little more resilient
  to breaking changes in analyzer that add support for new syntax that
  dart_style can't format yet.

## 0.2.13

* Support generic method *parameters* as well as arguments.

## 0.2.12

* Add support for assert() in constructor initializers.
* Correctly indent the right-hand side of `is` and `as` expressions.
* Avoid splitting in index operators when possible.
* Support generic methods (#556).

## 0.2.11+1

* Fix test to not depend on analyzer error message.

## 0.2.11

* Widen dependency on analyzer to allow 0.29.x.

## 0.2.10

* Handle metadata annotations before parameters with trailing commas (#520).
* Always split enum declarations if they end in a trailing comma (#529).
* Add `--set-exit-if-changed` to set the exit code on a change (#365).

## 0.2.9

* Require analyzer 0.27.4, which makes trailing commas on by default.

## 0.2.8

* Format parameter lists with trailing commas like argument lists (#447).

## 0.2.7

* Make it strong mode clean.
* Put labels on their own line (#43).
* Gracefully handle IO errors when failing to overwrite a file (#473).
* Add a blank line after local functions, to match top level ones (#488).
* Improve indentation in non-block-bodied control flow statements (#494).
* Better indentation on very long return types (#503).
* When calling from JS, guess at which error to show when the code cannot be
  parsed (#504).
* Force a conditional operator to split if the condition does (#506).
* Preserve trailing commas in argument and parameter lists (#509).
* Split arguments preceded by comments (#511).
* Remove newlines after script tags (#513).
* Split before a single named argument if the argument itself splits (#514).
* Indent initializers in multiple variable declarations.
* Avoid passing an invalid Windows file URI to analyzer.
* Always split comma-separated sequences that contain a trailing comma.

## 0.2.6

* Support deploying an npm package exporting a formatCode method.

## 0.2.4

* Better handling for long collections with comments (#484).

## 0.2.3

* Support messages in assert() (#411).
* Don't put spaces around magic generic method annotation comments (#477).
* Always put member metadata annotations on their own line (#483).
* Indent functions in named argument lists with non-functions (#478).
* Force the parameter list to split if a split occurs inside a function-typed
  parameter.
* Don't force a split for before a single named argument if the argument itself
  splits.

## 0.2.2

* Upgrade to analyzer 0.27.0.
* Format configured imports and exports.

## 0.2.1

* `--version` command line argument (#240).
* Split the first `.` in a method chain if the target splits (#255).
* Don't collapse states that differ by unbound rule constraints (#424).
* Better handling for functions in method chains (#367, #398).
* Better handling of large parameter metadata annotations (#387, #444).
* Smarter splitting around collections in named parameters (#394).
* Split calls if properties in a chain split (#399).
* Don't allow splitting inside empty functions (#404).
* Consider a rule live if it constrains a rule in the overflow line (#407).
* Allow splitting in prefix expressions (#410).
* Correctly constrain collections in argument lists (#420, #463, #465).
* Better indentation of collection literals (#421, #469).
* Only show a hidden directory once in the output (#428).
* Allow splitting between type and variable name (#429, #439, #454).
* Better indentation for binary operators in `=>` bodies (#434.
* Tweak splitting around assignment (#436, #437).
* Indent multi-line collections in default values (#441).
* Don't drop metadata on part directives (#443).
* Handle `if` statements without curly bodies better (#448).
* Handle loop statements without curly bodies better (#449).
* Allow splitting before `get` and `set` (#462).
* Add `--indent` to specify leading indent (#464).
* Ensure collection elements line split separately (#474).
* Allow redirecting constructors to wrap (#475).
* Handle index expressions in the middle of call chains.
* Optimize splitting lines with many rules.

## 0.2.0

* Treat functions nested inside function calls like block arguments (#366).

## 0.2.0-rc.4

* Smarter indentation for function arguments (#369).

## 0.2.0-rc.3

* Optimize splitting complex lines (#391).

## 0.2.0-rc.2

* Allow splitting between adjacent strings (#201).
* Force multi-line comments to the next line (#241).
* Better splitting in metadata annotations in parameter lists (#247).
* New optimized line splitter (#360, #380).
* Allow splitting after argument name (#368).
* Parsing a statement fails if there is unconsumed input (#372).
* Don't force `for` fully split if initializers or updaters do (#375, #377).
* Split before `deferred` (#381).
* Allow splitting on `as` and `is` expressions (#384).
* Support null-aware operators (`?.`, `??`, and `??=`) (#385).
* Allow splitting before default parameter values (#389).

## 0.2.0-rc.1

* **BREAKING:** The `indent` argument to `new DartFormatter()` is now a number
  of *spaces*, not *indentation levels*.

* This version introduces a new n-way constraint system replacing the previous
  binary constraints. It's mostly an internal change, but allows us to fix a
  number of bugs that the old solver couldn't express solutions to.

  In particular, it forces argument and parameter lists to go one-per-line if
  they don't all fit in two lines. And it allows function and collection
  literals inside expressions to indent like expressions in some contexts.
  (#78, #97, #101, #123, #139, #141, #142, #143, et. al.)

* Indent cascades more deeply when the receiver is a method call (#137).
* Preserve newlines in collections containing line comments (#139).
* Allow multiple variable declarations on one line if they fit (#155).
* Prefer splitting at "." on non-identifier method targets (#161).
* Enforce a blank line before and after classes (#168).
* More precisely control newlines between declarations (#173).
* Preserve mandatory newlines in inline block comments (#178).
* Splitting inside type parameter and type argument lists (#184).
* Nest blocks deeper inside a wrapped conditional operator (#186).
* Split named arguments if the positional arguments split (#189).
* Re-indent line doc comments even if they are flush left (#192).
* Nest cascades like expressions (#200, #203, #205, #221, #236).
* Prefer splitting after `=>` over other options (#217).
* Nested non-empty collections force surrounding ones to split (#223).
* Allow splitting inside with and implements clauses (#228, #259).
* Allow splitting after `=` in a constructor initializer (#242).
* If a `=>` function's parameters split, split after the `=>` too (#250).
* Allow splitting between successive index operators (#256).
* Correctly indent wrapped constructor initializers (#257).
* Set failure exit code for malformed input when reading from stdin (#359).
* Do not nest blocks inside single-argument function and method calls.
* Do nest blocks inside `=>` functions.

## 0.1.8+2

* Allow using analyzer 0.26.0-alpha.0.

## 0.1.8+1

* Use the new `test` package runner internally.

## 0.1.8

* Update to latest `analyzer` and `args` packages.
* Allow cascades with repeated method names to be one line.

## 0.1.7

* Update to latest analyzer (#177).
* Don't discard annotations on initializing formals (#197).
* Optimize formatting deeply nested expressions (#108).
* Discard unused nesting level to improve performance (#108).
* Discard unused spans to improve performance (#108).
* Harden splits that contain too much nesting (#108).
* Try to avoid splitting single-element lists (#211).
* Avoid splitting when the first argument is a function expression (#211).

## 0.1.6

* Allow passing in selection to preserve through command line (#194).

## 0.1.5+1, 0.1.5+2, 0.1.5+3

* Fix test files to work in main Dart repo test runner.

## 0.1.5

* Change executable name from `dartformat` to `dartfmt`.

## 0.1.4

* Don't mangle comma after function-typed initializing formal (#156).
* Add `--dry-run` option to show files that need formatting (#67).
* Try to avoid splitting in before index argument (#158, #160).
* Support `await for` statements (#154).
* Don't delete commas between enum values with doc comments (#171).
* Put a space between nested unary `-` calls (#170).
* Allow `-t` flag to preserve compatibility with old formatter (#166).
* Support `--machine` flag for machine-readable output (#164).
* If no paths are provided, read source from stdin (#165).

## 0.1.3

* Split different operators with the same precedence equally (#130).
* No spaces for empty for loop clauses (#132).
* Don't touch files whose contents did not change (#127).
* Skip formatting files in hidden directories (#125).
* Don't include trailing whitespace when preserving selection (#124).
* Force constructor initialization lists to their own line if the parameter
  list is split across multiple lines (#151).
* Allow splitting in index operator calls (#140).
* Handle sync* and async* syntax (#151).
* Indent the parameter list more if the body is a wrapped "=>" (#144).

## 0.1.2

* Move split conditional operators to the beginning of the next line.

## 0.1.1

* Support formatting enums (#120).
* Handle Windows line endings in multiline strings (#126).
* Increase nesting for conditional operators (#122).
