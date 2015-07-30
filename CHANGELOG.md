# 0.2.0

* Treat functions nested inside function calls like block arguments (#366).

# 0.2.0-rc.4

* Smarter indentation for function arguments (#369).

# 0.2.0-rc.3

* Optimize splitting complex lines (#391).

# 0.2.0-rc.2

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

# 0.2.0-rc.1

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

# 0.1.8+2

* Allow using analyzer 0.26.0-alpha.0.

# 0.1.8+1

* Use the new `test` package runner internally.

# 0.1.8

* Update to latest `analyzer` and `args` packages.
* Allow cascades with repeated method names to be one line.

# 0.1.7

* Update to latest analyzer (#177).
* Don't discard annotations on initializing formals (#197).
* Optimize formatting deeply nested expressions (#108).
* Discard unused nesting level to improve performance (#108).
* Discard unused spans to improve performance (#108).
* Harden splits that contain too much nesting (#108).
* Try to avoid splitting single-element lists (#211).
* Avoid splitting when the first argument is a function expression (#211).

# 0.1.6

* Allow passing in selection to preserve through command line (#194).

# 0.1.5+1, 0.1.5+2, 0.1.5+3

* Fix test files to work in main Dart repo test runner.

# 0.1.5

* Change executable name from `dartformat` to `dartfmt`.

# 0.1.4

* Don't mangle comma after function-typed initializing formal (#156).
* Add `--dry-run` option to show files that need formatting (#67).
* Try to avoid splitting in before index argument (#158, #160).
* Support `await for` statements (#154).
* Don't delete commas between enum values with doc comments (#171).
* Put a space between nested unary `-` calls (#170).
* Allow `-t` flag to preserve compatibility with old formatter (#166).
* Support `--machine` flag for machine-readable output (#164).
* If no paths are provided, read source from stdin (#165).

# 0.1.3

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

# 0.1.2

* Move split conditional operators to the beginning of the next line.

# 0.1.1

* Support formatting enums (#120).
* Handle Windows line endings in multiline strings (#126).
* Increase nesting for conditional operators (#122).
