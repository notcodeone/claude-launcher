import 'package:claude_launcher/src/integrations/claude_code_sessions.dart';
import 'package:claude_launcher/src/ui/code_sessions_view.dart';
import 'package:claude_launcher/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 9, 30, 12);

  Widget app(CodeSession session) => MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(
        width: 900,
        child: CodeSessionsSection(
          sessions: [session],
          onOpen: null,
          now: start.add(const Duration(minutes: 2)),
        ),
      ),
    ),
  );

  testWidgets('restored reference shows unknown state without progress', (
    tester,
  ) async {
    final session = CodeSession(id: 's', profileId: 'p', startedAt: start)
      ..state = CodeSessionState.unknown;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: CodeSessionsSection(
              sessions: [session],
              onOpen: (_) {},
              now: start,
            ),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Неизвестно', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('токены сменяются затуханием, подпись не мигает', (tester) async {
    final session = CodeSession(id: 's', profileId: 'p', startedAt: start)
      ..tokens = 3142;
    await tester.pumpWidget(app(session));
    expect(find.text('3,1'), findsOneWidget);
    expect(find.text('тыс. токенов'), findsOneWidget);

    session.tokens = 4870;
    await tester.pumpWidget(app(session));
    await tester.pump(const Duration(milliseconds: 200));
    // Посреди смены на экране оба числа, а подпись — одна.
    expect(find.text('3,1'), findsOneWidget);
    expect(find.text('4,9'), findsOneWidget);
    expect(find.text('тыс. токенов'), findsOneWidget);

    // pumpAndSettle не дождётся: у работающей сессии крутится индикатор.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('3,1'), findsNothing);
    expect(find.text('4,9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
