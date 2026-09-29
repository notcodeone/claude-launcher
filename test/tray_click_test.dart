import 'package:claude_launcher/src/tray.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late ClickDisambiguator clicks;
  const window = Duration(milliseconds: 60);

  setUp(() {
    calls = [];
    clicks = ClickDisambiguator(
      onSingle: () => calls.add('menu'),
      onDouble: () => calls.add('window'),
      window: window,
    );
  });
  tearDown(() => clicks.cancel());

  Future<void> wait() => Future<void>.delayed(window * 2);

  test('клик открывает меню, но не сразу', () async {
    clicks.click();
    expect(calls, isEmpty, reason: 'ждём, не будет ли второго клика');
    await wait();
    expect(calls, ['menu']);
  });

  test('двойной клик открывает окно, меню — нет', () async {
    clicks
      ..click()
      ..click();
    expect(calls, ['window']);
    await wait();
    expect(calls, ['window']);
  });

  test('два клика с паузой — два раза меню', () async {
    clicks.click();
    await wait();
    clicks.click();
    await wait();
    expect(calls, ['menu', 'menu']);
  });

  test('отмена: например, правый клик сам открыл меню', () async {
    clicks
      ..click()
      ..cancel();
    await wait();
    expect(calls, isEmpty);
  });
}
