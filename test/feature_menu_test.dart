import 'dart:io';

import 'package:claude_launcher/src/ui/feature_menu.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Шрифт системы — тексты меряются так же, как в окне; где его нет — пропуск.
  final sf = File('/System/Library/Fonts/SFNS.ttf');

  testWidgets('описания «Возможностей» — в одну строку окна', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.view(sf.readAsBytesSync().buffer))))
          .load();
    });
    await tester.binding.setSurfaceSize(const Size(560, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Окно 560 с полями по 24 — ширина меню под шапкой.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: FeaturesPage(padding: EdgeInsets.zero, onOpen: _ignore),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final texts = [
      for (final section in appFeatures)
        for (final tile in section.tiles) tile.text,
    ];
    for (final text in texts) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '«$text» не влезает в строку',
      );
    }
  }, skip: !sf.existsSync());
}

void _ignore(String _) {}
