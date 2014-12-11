The dart_style package defines an automatic, opinionated formatter for Dart
code. It replaces the whitespace in your program with what it deems to be the
best formatting for it. Resulting code should following the [Dart style guide][]
but, moreso, should look nice to most human readers, most of the time.

It handles indentation, inline whitespace and (by far the most difficult),
intelligent line wrapping. It has no problems with nested collections, function
expressions, long argument lists, or otherwise tricky code.

**The formatter is at an alpha state right now. It does a good job on most code,
and I'd love to have you try it and report bugs, but it has known issue and its
output will change over time.**

## Running it

The package exposes a simple command-line wrapper around the core formatting
library. The easiest way to invoke it is to [globally activate][] the package
and let pub put its executable on your path:

    $ pub global activate dart_style
    $ dartfmt ...

If you don't want `dartfmt` on your path, you can run it explicitly:

    $ pub global activate dart_style --no-executables
    $ pub global run dart_style:format ...

The formatter takes a list of paths, which can point to directories or files.
If the path is a directory, it processes every `.dart` file in that directory
or any of its subdirectories.

By default, it formats each file and just prints the resulting code to stdout.
If you pass `-w`, it will instead overwrite your existing files with the
formatted results.

You may pass an `--line-length` option to control the width of the page that it
wraps lines to fit within, but you're strongly encouraged to keep the default
line length of 80 columns.

## Using it programmatically

The package also exposes a single dart_style library containing a programmatic
API for formatting code. Simple usage looks like this:

    import 'package:dart_style/dart_style.dart';

    main() {
      var formatter = new DartFormatter();

      try {
        formatter.format("""
        library an_entire_compilation_unit;

        class SomeClass {}
        """);

        formatter.formatStatement("aSingle(statement);");
      } on FormatterException catch (ex) {
        print(ex);
      }
    }

[dart style guide]: https://www.dartlang.org/articles/style-guide/
[globally activate]: https://www.dartlang.org/tools/pub/cmd/pub-global.html

## Stability

You can rely on the formatter to not break your code or change its semantics.
If it does do so, this is a critical bug and we'll fix it quickly.

The heuristics the formatter uses to determine the "best" way to split a line
are still being developed and may change over time. The ones today cover most
common uses, but there's room for more refinement. We don't promise that code
produced by the formatter today will be identical to the same code run through
a later version of the formatter. We do hope that you'll like the output of the
later version more.