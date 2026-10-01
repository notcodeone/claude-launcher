import 'package:claude_launcher/src/ui/theme.dart';
import 'package:claude_launcher/src/ui/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('подсветка уходит вместе с курсором и у неактивного пункта', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder(
              valueListenable: enabled,
              builder: (_, on, _) => HoverSurface(
                onTap: on ? () {} : null,
                child: const SizedBox(width: 200, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
    double alpha() =>
        (tester
                    .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                    .decoration
                as BoxDecoration?)
            ?.color
            ?.a ??
        0;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(HoverSurface)));
    await tester.pumpAndSettle();
    expect(alpha(), closeTo(HoverSurface.hoverAlpha, 0.001));

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(alpha(), 0);

    await mouse.moveTo(tester.getCenter(find.byType(HoverSurface)));
    await tester.pumpAndSettle();
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(alpha(), 0);
  });
}
