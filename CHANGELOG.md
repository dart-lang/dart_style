# 0.1.3

* Split different operators with the same precedence equally (#130).
* No spaces for empty for loop clauses (#132).
* Don't touch files whose contents did not change (#127).
* Skip formatting files in hidden directories (#125).
* Don't include trailing whitespace when preserving selection (#124).
* Force constructor initialization lists to their own line if the parameter
  list is split across multiple lines (#151).
* Allow splitting in index operator calls (#140).

# 0.1.2

* Move split conditional operators to the beginning of the next line.

# 0.1.1

* Support formatting enums (#120).
* Handle Windows line endings in multiline strings (#126).
* Increase nesting for conditional operators (#122).