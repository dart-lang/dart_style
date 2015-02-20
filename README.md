The dart_style package defines an automatic, opinionated formatter for Dart
code. It replaces the whitespace in your program with what it deems to be the
best formatting for it. Resulting code should following the [Dart style guide][]
but, moreso, should look nice to most human readers, most of the time.

It handles indentation, inline whitespace and (by far the most difficult),
intelligent line wrapping. It has no problems with nested collections, function
expressions, long argument lists, or otherwise tricky code.

## Running it

The package exposes a simple command-line wrapper around the core formatting
library. The easiest way to invoke it is to [globally activate][] the package
and let pub put its executable on your path:

    $ pub global activate dart_style
    $ dartfmt ...

If you don't want `dartformat` on your path, you can run it explicitly:

    $ pub global activate dart_style --no-executables
    $ pub global run dart_style:format ...

The formatter takes a list of paths, which can point to directories or files.
If the path is a directory, it processes every `.dart` file in that directory
or any of its subdirectories.

By default, it formats each file and just prints the resulting code to stdout.
If you pass `-w`, it will instead overwrite your existing files with the
formatted results.

You may pass a `--line-length` option to control the width of the page that it
wraps lines to fit within, but you're strongly encouraged to keep the default
line length of 80 columns.

## Validating files

If you want to use the formatter in something like a [presubmit script][] or
[commit hook][], you can use the `--dry-run` option. If you pass that, the
formatter prints the paths of the files whose contents would change if the
formatter were run normally. If it prints no output, then everything is already
correctly formatted.

[presubmit script]: http://www.chromium.org/developers/how-tos/depottools/presubmit-scripts
[commit hook]: http://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks

## Using it programmatically

The package also exposes a single dart_style library containing a programmatic
API for formatting code. Simple usage looks like this:

    import 'package:dart_style/dart_style.dart';

    main() {
      var formatter = new DartFormatter();

      try {
        print(formatter.format("""
        library an_entire_compilation_unit;

        class SomeClass {}
        """));

        print(formatter.formatStatement("aSingle(statement);"));
      } on FormatterException catch (ex) {
        print(ex);
      }
    }

## Stability

You can rely on the formatter to not break your code or change its semantics.
If it does do so, this is a critical bug and we'll fix it quickly.

The rules the formatter uses to determine the "best" way to split a line may
change over time. We don't promise that code produced by the formatter today
will be identical to the same code run through a later version of the formatter.
We do hope that you'll like the output of the later version more.

[bugs]: https://github.com/dart-lang/dart_style/issues
[dart style guide]: https://www.dartlang.org/articles/style-guide/
[globally activate]: https://www.dartlang.org/tools/pub/cmd/pub-global.html
