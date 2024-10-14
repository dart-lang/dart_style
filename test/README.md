The formatter is tested similar to a compiler where most of the test
functionality is "end-to-end" tests that validate that a given input produces
an expected output.

## Formatting file format

The formatting test expectations live in test data files ending in ".unit" or
".stmt". The ".unit" extension is for tests whose input should be parsed as an
entire Dart compilation unit (roughly library or part file). The ".stmt" files
parse each expectation as a statement.

These test files have a custom diff-like format:

```
40 columns                              |
>>> (indent 4) arithmetic operators
var a=1+2/(3*-b~/4);
<<<
    var a = 1 + 2 / (3 * -b ~/ 4);
```

If the first line contains a `|`, then it indicates the page width that all
tests in this file should be formatted using. All other text on that line is
ignored. This is used so that tests can test line wrapping behavior without
having to create long code to force things to wrap.

The `>>>` line begins a test. It may have comment text afterwards describing the
test. If the line contains `(indent <n>)` for some `n`, then the formatter is
told to run with that level of indentation. This is mainly for regression tests
where the erroneous code appeared deeply nested inside some class or function
and the test wants to reproduce that same surrounding indentation.

Lines after the `>>>` line are the input code to be formatted.

The `<<<` ends the input and begins the expected formatted result. The end of
the file or the next `>>>` marks the end of the expected output.

For each pair of input and expected output, the test runner creates a separate
test. It runs the input code through the formatter and validates that the
resulting code matches the expectation.

Lines starting with `###` are treated as comments and are ignored.

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
