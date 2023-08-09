**Note: This is an experimental branch of dart_style. By default, it behaves
exactly the same as the master branch, but it contains *opt-in* support for a
prototype implementation of a new experimental set of style rules.**

This experiment holistically changes dart_style's formatting to better reflect
the style used by the Flutter framework and many Flutter users.

The most visible change is that it always formats argument lists the way that
you get when you put trailing commas on them, like:

```dart
function(
  argument,
  argument,
  argument
);
```

In addition, it treats trailing commas as whitespace: It will add them if an
argument list needs to split across lines, and it will remove them from argument
lists and other constructs that do fit on one line.

There are many other formatting changes throughout the language in order to look
consistent with that style. It touches almost everything: constructor
initializers, type arguments, closures in argument lists, method chains, etc.

You can try out the experimental style by any of:

-   When running `dart format` on the command line, pass `-e` or
    `--experimental-style`.

-   If a file contains this magic comment:

    ```dart
    // DO NOT SUBMIT USE DART FORMAT EXPERIMENT
    ```

    then the entire file will be formatted using the new style. This is a
    convenient way to try out the new style when using the formatter through an
    IDE integration. Once your IDE is using this branch of the formatter,
    simply add that comment to a file and it will take effect.

-   When using the formatter as a library, pass `experimentalStyle: true` when
    constructing a DartFormatter instance.

This prototype exists to get user feedback on the proposed style rules, so if
you try it out, please do let us know what you think.

---

The dart_style package defines an automatic, opinionated formatter for Dart
code. It replaces the whitespace in your program with what it deems to be the
best formatting for it. Resulting code should follow the [Dart style guide][]
but, moreso, should look nice to most human readers, most of the time.

[dart style guide]: https://dart.dev/guides/language/effective-dart/style

The formatter handles indentation, inline whitespace, and (by far the most
difficult) intelligent line wrapping. It has no problems with nested
collections, function expressions, long argument lists, or otherwise tricky
code.

The formatter turns code like this:

```dart
// BEFORE formatting
if (tag=='style'||tag=='script'&&(type==null||type == TYPE_JS
      ||type==TYPE_DART)||
  tag=='link'&&(rel=='stylesheet'||rel=='import')) {}
```

into:

```dart
// AFTER formatting
if (tag == 'style' ||
  tag == 'script' &&
      (type == null || type == TYPE_JS || type == TYPE_DART) ||
  tag == 'link' && (rel == 'stylesheet' || rel == 'import')) {}
```

The formatter will never break your code&mdash;you can safely invoke it
automatically from build and presubmit scripts.

## Style fixes

The formatter can also apply non-whitespace changes to make your code
consistently idiomatic. You must opt into these by passing either `--fix` which
applies all style fixes, or any of the `--fix-`-prefixed flags to apply specific
fixes.

For example, running with `--fix-named-default-separator` changes this:

```dart
greet(String name, {String title: "Captain"}) {
  print("Greetings, $title $name!");
}
```

into:

```dart
greet(String name, {String title = "Captain"}) {
  print("Greetings, $title $name!");
}
```

## Using the formatter

The formatter is part of the unified [`dart`][] developer tool included in the
Dart SDK, so most users get it directly from there. That has the latest version
of the formatter that was available when the SDK was released.

[`dart`]: https://dart.dev/tools/dart-tool

IDEs and editors that support Dart usually provide easy ways to run the
formatter. For example, in WebStorm you can right-click a .dart file and then
choose **Reformat with Dart Style**.

Here's a simple example of using the formatter on the command line:

    $ dart format test.dart

This command formats the `test.dart` file and writes the result to the
file.

`dart format` takes a list of paths, which can point to directories or files. If
the path is a directory, it processes every `.dart` file in that directory or
any of its subdirectories.

By default, it formats each file and write the formatting changes to the files.
If you pass `--output show`, it prints the formatted code to stdout.

You may pass a `-l` option to control the width of the page that it wraps lines
to fit within, but you're strongly encouraged to keep the default line length of
80 columns.

### Validating files

If you want to use the formatter in something like a [presubmit script][] or
[commit hook][], you can pass flags to omit writing formatting changes to disk
and to update the exit code to indicate success/failure:

    $ dart format --output=none --set-exit-if-changed .

[presubmit script]: https://www.chromium.org/developers/how-tos/depottools/presubmit-scripts
[commit hook]: https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks

## Running other versions of the formatter CLI command

If you need to run a different version of the formatter, you can
[globally activate][] the package from the dart_style package on
pub.dev:

[globally activate]: https://dart.dev/tools/pub/cmd/pub-global

    $ pub global activate dart_style
    $ pub global run dart_style:format ...

## Using the dart_style API

The package also exposes a single dart_style library containing a programmatic
API for formatting code. Simple usage looks like this:

```dart
import 'package:dart_style/dart_style.dart';

main() {
  final formatter = DartFormatter();

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
```

## Other resources

* Before sending an email, see if you are asking a
  [frequently asked question][faq].

* Before filing a bug, or if you want to understand how work on the
  formatter is managed, see how we [track issues][].

[faq]: https://github.com/dart-lang/dart_style/wiki/FAQ
[track issues]: https://github.com/dart-lang/dart_style/wiki/Tracking-issues
