# 0.1.8-dev

* Update to latest args.
* Allow cascades with repeated method names to be one line.

# 0.1.7

* Update to latest analyzer (#177).
* Don't discard annotations on initializing formals (#197).
* Optimize formatting deeply nested expressions (#108).
* Discard unused nesting level to improve performance (#108).
* Discard unused spans to improve performance (#108).
* Harden splits that containg too much nesting (#108).
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
* Allow `-t` flag to preserve compability with old formatter (#166).
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
