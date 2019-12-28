import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

void main() {
  test('auto insert semi colon when possible', () {
    final formatter = DartFormatter();
    var actual = '''
    import 'thing.dart'
    void main() {
      print()
      thing
      ..onClick.listen(() {
        window.alert('clicked')
      })
    }
    ''';
    var matcher = '''
    import 'thing.dart';
    void main() {
      print();
      thing
      ..onClick.listen(() {
        window.alert('clicked');
      });
    }
    ''';
    var output = formatter.format(actual);
    var formattedTarget = formatter.format(matcher);

    expect(output, formattedTarget);
  });
}
