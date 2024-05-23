---
[English](./README.md) |中文
---

这是一个[dart_style](https://github.com/dart-lang/dart_style)包的分支，为了满足我自己的需求做了一些轻微的修改。当前的更改包括：

- [x] 将缩进从2个空格改为4个空格
- [x] 在构造函数中移除了闭括号和冒号之间的空格：

```dart
class BN {
    final int a;
    final int b;
    BN({
        required int a,
        required int b,
    }): a = a,  // was })  : a = a ,
        b = b;
}
```

受到 [这个](https://github.com/mkakabaev/dart_style) 项目的启发

## 编译自己的代码格式化工具

1. 克隆[本仓库](https://github.com/kennydiff/my_dart_style.git)
2. 编译此包

```sh
dart pub get
dart compile exe bin/format.dart -o build/my_dartfmt
```

3. 将可执行文件移动到 PATH 目录中。我个人使用我自己的 `~/bin`

```sh
mv build/my_dartfmt ~/bin   # PATH 中的任何目录，我使用`~/bin`目录
```

## 在 VSCode 中启用新的格式化工具

1. 在VSCode插件管理器里安装 [Custom Local Formatters](https://github.com/JKillian/vscode-custom-local-formatters) 这个插件
2. 添加到 VSCode 的设置 JSON 中（全局、工作区、文件夹 - 根据您的选择）:

```jsonc
"dart.enableSdkFormatter": false,
   
"[dart]": {
    // ...
    "editor.defaultFormatter": "jkillian.custom-local-formatters",
    "editor.tabSize": 4,
    // ... 
},

"customLocalFormatters.formatters": [
    {
        "command": "my_dartfmt -l 120",
        "languages": ["dart"]
    }
],

```

## 注意事项

这个分支只修改了以下2个文件，对这个项目的修改，建议不要使用VSCode，因为VSCode的改版的代码格式化工具会让这两个文件重新格式化，导致未来执行 `Sync Fork`的时候产生合并冲突。
```shell
lib/src/constants.dart
lib/src/short/source_visitor.dart
```



以下是原始的 README ...

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
