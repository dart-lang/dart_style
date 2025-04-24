The dart_style package defines an opinionated, [minimally configurable][config]
automated formatter for Dart code.

[config]: https://github.com/dart-lang/dart_style/wiki/Configuration

It replaces the whitespace in your program with what it deems to be the
best formatting for it. It also makes minor changes around non-semantic
punctuation like trailing commas and brackets in parameter lists.

The resulting code should follow the [Dart style guide][] and look nice to most
human readers, most of the time.

[dart style guide]: https://dart.dev/guides/language/effective-dart/style

The formatter handles indentation, inline whitespace, and (by far the most
difficult) intelligent line wrapping. It has no problems with nested
collections, function expressions, long argument lists, or otherwise tricky
code.

The formatter turns code like this:

```dart
process = await Process.start(path.join(p.pubCacheBinPath,Platform.isWindows
?'${command.first}.bat':command.first,),[...command.sublist(1),'web:0',
// Allow for binding to a random available port.
],workingDirectory:workingDir,environment:{'PUB_CACHE':p.pubCachePath,'PATH':
path.dirname(Platform.resolvedExecutable)+(Platform.isWindows?';':':')+
Platform.environment['PATH']!,},);
```

into:

```dart
process = await Process.start(
  path.join(
    p.pubCacheBinPath,
    Platform.isWindows ? '${command.first}.bat' : command.first,
  ),
  [
    ...command.sublist(1), 'web:0',
    // Allow for binding to a random available port.
  ],
  workingDirectory: workingDir,
  environment: {
    'PUB_CACHE': p.pubCachePath,
    'PATH':
        path.dirname(Platform.resolvedExecutable) +
        (Platform.isWindows ? ';' : ':') +
        Platform.environment['PATH']!,
  },
);
```

The formatter will never break your code&mdash;you can safely invoke it
automatically from build and presubmit scripts.

## Formatting files

The formatter is part of the unified [`dart`][] developer tool included in the
Dart SDK, so most users run it directly from there using `dart format`.

[`dart`]: https://dart.dev/tools/dart-tool

IDEs and editors that support Dart usually provide easy ways to run the
formatter. For example, in Visual Studio Code, formatting Dart code will use
the dart_style formatter by default. Most users have it set to reformat every
time they save a file.

Here's a simple example of using the formatter on the command line:

```sh
$ dart format my_file.dart
```

This command formats the `my_file.dart` file and writes the result back to the
same file.

The `dart format` command takes a list of paths, which can point to directories
or files. If the path is a directory, it processes every `.dart` file in that
directory and all of its subdirectories.

By default, `dart format` formats each file and writes the result back to the
same files. If you pass `--output show`, it prints the formatted code to stdout
and doesn't modify the files.

## Validating formatting

If you want to use the formatter in something like a [presubmit script][] or
[commit hook][], you can pass flags to omit writing formatting changes to disk
and to update the exit code to indicate success/failure:

```sh
$ dart format --output=none --set-exit-if-changed .
```

[presubmit script]: https://www.chromium.org/developers/how-tos/depottools/presubmit-scripts
[commit hook]: https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks

## Using the formatter as a library

The `dart_style package exposes a simple [library API][] for formatting code.
Basic usage looks like this:

[library api]: https://pub.dev/documentation/dart_style/latest/

```dart
import 'package:dart_style/dart_style.dart';

main() {
  final formatter = DartFormatter(
    languageVersion: DartFormatter.latestLanguageVersion,
  );

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
