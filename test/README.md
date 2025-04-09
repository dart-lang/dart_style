The formatter is tested similar to a compiler where most of the test
functionality is "end-to-end" tests that validate that a given input produces
an expected output.

## Formatting file format

The formatting test expectations live in test data files ending in ".unit" or
".stmt". The ".unit" extension is for tests whose input should be parsed as an
entire Dart compilation unit (roughly library or part file). The ".stmt" files
parse each expectation as a statement.

Each test file has an optional header followed by a number of test cases. Lines
that start with `###` are comments and are ignored.

### Test file header

If the first line contains a `|`, then it indicates the page width that all
tests in this file should be formatted using. All other text on that line is
ignored. This is used so that tests can test line wrapping behavior without
having to create long code to force things to wrap.

After that, if there is a line containing parenthesized options like
`(indent 4)` or `(experiment monads)` then those options are applied to all
test cases in the file.

### Test cases

Each test case begins with a header line like:

```
>>> (indent 4) Some description.
```

The `>>>` marks the beginning of a new test. After that are optional
parenthesized options that will be applied to that test. then an optional
description for the test. Lines after that define the input code to be
formatted.

After the input are one or more output sections. Each output section starts
with a header like:

```
<<< 3.7 Optional description.
```

The `<<<` marks the beginning of a new output section. If it has a language
version number, then this output is expected only on that language version. If
it has no version number, then this is the expected output on all versions.

### Test options

A few parenthesized options are supported:

* `(indent <n>)` Tells the formatter to apply that many spaces of leading
  indentation. This is mainly for regression tests where the erroneous code
  appeared deeply nested inside some class or function and the test wants to
  reproduce that same surrounding indentation.

* `(experiment <name>)` Enable that named experiment in the parser and
  formatter. A test can have multiple of these.

* `(trailing_commas preserve)` Enable the preserved trailing commas option.

### Test versions

All tests in the "short" directory are run at language version
[DartFormatter.latestShortStyleLanguageVersion].

Tests in the "tall" directory are run (potentially) on multiple versions. By
default, tests are run against every language version from just after
[DartFormatter.latestShortStyleLanguageVersion] up to
[DartFormatter.latestLanguageVersion].

If the test has an output expectation for a specific version, then when the
test is run at that version, it is validated against that output. If the test
has an output expectation with no version marker, than that is the default
expectation for all other unspecified versions. If a test has no unversioned
output expectation, then it is only run against the versions that it has
expectations for.

For example, let's say the supported tall versions are 3.7, 3.8, and 3.9. A
test like:

```
<<<
some  .  code;
>>>
some.code;
```

This will be run at versions 3.7, 3.8, and 3.9. For all of them, the expected
output is `some.code;`.

A test like:

```
<<<
some  .  code;
>>>
some.code;
>>> 3.7
some . code ;
```

This will be run at versions 3.7, 3.8, and 3.9. For version 3.7, the expected
output is `some . code ;`. For 3.7 and 3.9, the expected output is `some.code;`.

A test like:

```
<<<
some  .  code;
>>> 3.8
some.code;
>>> 3.9
some . code ;
```

Is *only* run at versions 3.8 and 3.9. At 3.8, the expected output is
`some.code;` and at 3.8 it's `some . code ;`. Tests like this are usually for
testing language features or formatter features that didn't exist prior to some
version, like preserved trailing commas, or null-aware elements.

## Test directories

These expectation files are organized in subdirectories of `test/`. The
formatter currently supports two separate formatting styles.

The older short style tests are organized like:

```
short/comments/     - Test comment handling.
short/regression/   - Regression tests. File names correspond to issues.
short/selections/   - Test how the formatter preserves selection information.
short/splitting/    - Test line splitting behavior.
short/whitespace/   - Test whitespace insertion and removal.
```

These tests are all run by `short_format_test.dart`.

The newer tall style tests are:

```
tall/declaration/  - Typedef, class, enum, extension, mixin, and member
                     declarations. Includes constructors, getters, setters,
                     methods, and fields, but not functions and variables,
                     which are in their own directories below.
tall/expression/   - Expressions and collection elements.
tall/function/     - Function declarations.
tall/invocation/   - Function and member invocations.
tall/other/        - Selections, comment markers, and other odds and ends.
tall/pattern/      - Patterns.
tall/statement/    - Statements.
tall/top_level/    - Top-level directives.
tall/type/         - Type annotations.
tall/variable/     - Top-level and local variable declarations.
```

These tests are all run by `tall_format_test.dart`.

Eventually support for the older "short" style will be removed.
