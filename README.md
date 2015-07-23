The dart_style package defines an automatic, opinionated formatter for Dart
code. It replaces the whitespace in your program with what it deems to be the
best formatting for it. Resulting code should following the [Dart style guide][]
but, moreso, should look nice to most human readers, most of the time.

[dart style guide]: https://www.dartlang.org/articles/style-guide/

It handles indentation, inline whitespace and (by far the most difficult),
intelligent line wrapping. It has no problems with nested collections, function
expressions, long argument lists, or otherwise tricky code.

## Usage

The package exposes a simple command-line wrapper around the core formatting
library. The easiest way to invoke it is to [globally activate][] the package
and let pub put its executable on your path:

    $ pub global activate dart_style
    $ dartfmt ...

[globally activate]: https://www.dartlang.org/tools/pub/cmd/pub-global.html

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

### Validating files

If you want to use the formatter in something like a [presubmit script][] or
[commit hook][], you can use the `--dry-run` option. If you pass that, the
formatter prints the paths of the files whose contents would change if the
formatter were run normally. If it prints no output, then everything is already
correctly formatted.

[presubmit script]: http://www.chromium.org/developers/how-tos/depottools/presubmit-scripts
[commit hook]: http://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks

### Using it programmatically

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

## FAQ

### Why have a formatter?

The has a few goals, in order of descending priority:
    
1.  **Produce consistently formatted code.** Consistent style improves
    readability because you aren't distracted by variance in style between
    different parts of a program. It makes it easier to contribute to others'
    code because their style will already be familiar to you.
    
2.  **End debates about style issues in code reviews.** This consumes an
    astonishingly large quantity of very valuable engineering energy. Style
    debates are time-consuming, upset people, and rarely change anyone's mind.
    They make code reviews take longer and be more acromonious.
    
3.  **Free users from having to think about and apply formatting.** When
    writing code, you don't have to try to figure out the best way to split a
    line and then pain-stakingly add in the line breaks. When you do a global
    refactor that changes the length of some identifier, you don't have to go
    back and rewrap all of the lines. When you're in the zone, you can just
    pump out code and let the formatter tidy it up for you as you go.
    
4.  **Produce beautiful, readable output that helps users understand the code.**
    We could solve all of the above goals with a formatter that just removed
    *all* whitespace, but that wouldn't be very human-friendly. So, finally,
    the formatter tries very hard to produce output that is not just consistent
    but readable to a human. It tries to use indentation and line breaks to
    highlight the structure and organization of the code.
    
    In several cases, the formatter has pointed out bugs where the existing
    indentation was misleading and didn't represent what the code actually did.
    For example, automated formatted would have helped make Apple's
    ["gotofail"][gotofail] security bug easier to notice:
    
    ```c
    if ((err = SSLHashSHA1.update(&hashCtx, &signedParams)) != 0)
        goto fail;
        goto fail;
    if ((err = SSLHashSHA1.final(&hashCtx, &hashOut)) != 0)
        goto fail;
    ```
    
    The formatter would change this to:
    
    ```c
    if ((err = SSLHashSHA1.update(&hashCtx, &signedParams)) != 0)
        goto fail;
    goto fail; // <-- not clearly not under the "if".
    if ((err = SSLHashSHA1.final(&hashCtx, &hashOut)) != 0)
        goto fail;
    ```

[gotofail]: https://gotofail.com/

### I don't like the output!

First of all, that's not a question. But, yes, sometimes you may dislike the
output of the formatter. This may be a bug or it may be a deliberate stylistic
choice of the formatter that you disagree with. The simplest way to find out is
to file an [issue][].

[issue]: https://github.com/dart-lang/dart_style/issues

Now that the formatter is fairly mature, it's more likely that the output is
deliberate. If your bug gets closed as "as designed", try not to be too sad.
Even if the formatter doesn't follow your personal preferences, what it *does*
do is spare you the effort of hand-formatting, and ensure your code is
*consistently* formatted. I hope you'll appreciate the real value in both of
those.

### How stable is it?

You can rely on the formatter to not break your code or change its semantics.
If it does do so, this is a critical bug and we'll fix it quickly.

The rules the formatter uses to determine the "best" way to split a line may
change over time. We don't promise that code produced by the formatter today
will be identical to the same code run through a later version of the formatter.
We do hope that you'll like the output of the later version more.

### Why can't I tell the formatter to ignore a region of code?

Even a really sophisticated formatter can't beat a human in *all* cases. Our
semantic knowledge of the code can let us show more than the formatter can. One
escape hatch would be to have a comment telling the formatter "leave this
alone".

This might help the fourth goal above, but does so at the expense of the first
three. We want code that is *consistent* and we want you to stop thinking about
formatting. If you can decide to turn off the formatter, now you have regions
of code that are inconsistent by design.

Further, you're right back into debates about how the code in there should be
formatted, with the extra bonus of now debating whether or not that annotation
should be used and where. None of this is making your life better.

Yes, *maybe* you can hand-format some things better than the formatter. (Though,
in most cases where users have asked for this, I've seen formatting errors in
the examples they provided!) But does doing that really add enough value to
make up for re-opening that can of worms?

### Why does the formatter mess up my collection literals?

Large collection literals are often used to define big chunks of structured
data, like:

```dart
/// Maps ASCII character values to what kind of character they represent.
const characterTypes = const [
  other, other, other, other, other, other, other, other,
  other, white, white, other, other, white,              
  other, other, other, other, other, other, other, other,
  other, other, other, other, other, other, other, other,
  other, other, white,                                   
  punct, other, punct, punct, punct, punct, other,       
  brace, brace, punct, punct, comma, punct, punct, punct,
  digit, digit, digit, digit, digit,                     
  digit, digit, digit, digit, digit,                     
  punct, punct, punct, punct, punct, punct, punct,       
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, brace, punct, brace, punct, alpha, other,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, brace, punct, brace, punct               
];
```

The formatter doesn't know those newlines are meaningful, so it wipes it out
to:

```dart
/// Maps ASCII character values to what kind of character they represent.
const characterTypes = const [
  other,
  other,
  other,
  
  // lots more ...
  
  punct,
  brace,
  punct             
];
```

In many cases, ignoring these newlines is a good thing. If you've removed a few
items from a list, it's a win for the formatter to repack it into one line if
it fits. But here it clearly loses useful information.

Fortunately, in most cases, structured collections like this have comments
describing their structure:

```dart
const characterTypes = const [
  other, other, other, other, other, other, other, other,
  other, white, white, other, other, white,
  other, other, other, other, other, other, other, other,
  other, other, other, other, other, other, other, other,
  other, other, white,
  punct, other, punct, punct, punct, punct, other, //          !"#$%&´
  brace, brace, punct, punct, comma, punct, punct, punct, //   ()*+,-./
  digit, digit, digit, digit, digit, //                        01234
  digit, digit, digit, digit, digit, //                        56789
  punct, punct, punct, punct, punct, punct, punct, //          :;<=>?@
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha, //   ABCDEFGH
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, brace, punct, brace, punct, alpha, other, //   YZ[\]^_'
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha, //   abcdefgh
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, alpha, alpha, alpha, alpha, alpha, alpha,
  alpha, alpha, brace, punct, brace, punct  //                 yz{|}~
];
```

In that case, the formatter is smart enough to recognize this and preserve your
original newlines. So, if you have a collection that you have carefully split
into lines, add at least one line comment somewhere inside it to get it to
preserve all of the newlines in it.

### Why doesn't the formatter handle multi-line `if` statements better?

If you have a statement like:

```dart
if (someVeryLongConditional || anotherLongConditional) function(argument, argument);
```

It will format it like:

```dart
if (someVeryLongConditional || anotherLongConditional) function(
    argument, argument);
```

You might expect it to break before `function`. But the Dart style guide
explicitly forbids multi-line `if` statements that do not use `{}` bodies.
Given that, there's never a reason for the formatter to allow splitting after
the condition. This is true of other control flow statements too, of course.

### Why doesn't the formatter add curlies or otherwise clean up code then?

The formatter has a simple, restricted charter: it rewrites *only the
non-semantic whitespace of your program.* It makes absolutely no other changes
to your code.

This helps keep the scope of the project limited. The set of "clean-ups" you
may want to do is unbounded and much fuzzier to define.

It also makes it more reliable to run the formatter automatically in things
like presubmit scripts where a human may not be vetting the output. If the
formatter only touches whitespace, it's easier for a human to trust its output.
