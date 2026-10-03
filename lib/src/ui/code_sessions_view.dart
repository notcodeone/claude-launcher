import 'dart:math';

import 'package:flutter/material.dart';

import '../integrations/claude_code_sessions.dart';
import 'theme.dart';
import 'widgets.dart';

/// Цвет состояния сессии. Им же окрашена точка на кнопке «Показать окно»,
/// когда сессии на карточке свёрнуты.
Color sessionColor(Palette p, CodeSessionState state) => switch (state) {
  CodeSessionState.unknown => p.muted,
  CodeSessionState.working => p.text,
  CodeSessionState.needsPermission => p.warning,
  CodeSessionState.needsAnswer => p.info,
  CodeSessionState.done => p.success,
};

String sessionLabel(CodeSessionState state) => switch (state) {
  CodeSessionState.unknown => 'Неизвестно',
  CodeSessionState.working => 'Работает',
  CodeSessionState.needsPermission || CodeSessionState.needsAnswer => 'Ожидает',
  CodeSessionState.done => 'Готово',
};

/// «12 с», «2 мин 14 с», «1 ч 5 мин» — как счётчик в самом Claude Code.
String formatElapsed(Duration elapsed) {
  if (elapsed.inSeconds < 60) return '${max(0, elapsed.inSeconds)} с';
  if (elapsed.inMinutes < 60) {
    return '${elapsed.inMinutes} мин ${elapsed.inSeconds % 60} с';
  }
  final minutes = elapsed.inMinutes % 60;
  return minutes == 0
      ? '${elapsed.inHours} ч'
      : '${elapsed.inHours} ч $minutes мин';
}

/// «850 токенов», «3,1 тыс. токенов», «1,2 млн токенов».
String formatTokens(int count) {
  final (number, unit) = tokenParts(count);
  return '$number $unit';
}

/// Число и подпись по отдельности: «3,1» и «тыс. токенов».
(String, String) tokenParts(int count) {
  if (count < 1000) return ('$count', _tokensWord(count));
  final thousands = count / 1000;
  if (thousands.round() < 1000) return (_short(thousands), 'тыс. токенов');
  return (_short(count / 1000000), 'млн токенов');
}

/// Одна цифра после запятой — только у небольших чисел: «3,1», «12», «125».
String _short(double value) {
  if (value >= 9.95) return value.round().toString();
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text.replaceFirst('.', ',');
}

String _tokensWord(int count) {
  final lastTwo = count % 100;
  final last = count % 10;
  if (last == 1 && lastTwo != 11) return 'токен';
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) {
    return 'токена';
  }
  return 'токенов';
}

String _clock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

/// Сессии Claude Code под линией внизу карточки профиля:
/// «◌ Работает · parking-server ········ 2 мин · 3,1 тыс. токенов».
class CodeSessionsSection extends StatelessWidget {
  const CodeSessionsSection({
    super.key,
    required this.sessions,
    required this.onOpen,
    required this.now,
  });

  /// Последние сверху.
  final List<CodeSession> sessions;

  /// Открывает сессию в Claude; null — сейчас нельзя (идёт переключение).
  final void Function(CodeSession session)? onOpen;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      // Справа карточка отступает 8 под кнопки-иконки; линии и времени
      // нужны те же 16, что и слева.
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: p.divider),
          const SizedBox(height: 8),
          for (final session in sessions)
            // Ключ — чтобы при пересортировке счётчик не перескочил к другой сессии.
            _SessionRow(
              key: ValueKey(session.id),
              session: session,
              onOpen: onOpen,
              now: now,
            ),
        ],
      ),
    );
  }
}

const _iconBox = 14.0;
const _iconGap = 8.0;

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    super.key,
    required this.session,
    required this.onOpen,
    required this.now,
  });

  final CodeSession session;
  final void Function(CodeSession session)? onOpen;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = Theme.of(context).textTheme.bodySmall!;
    final textStyle = base.copyWith(fontSize: 13, color: p.text);
    final color = sessionColor(p, session.state);
    final working = session.state == CodeSessionState.working;
    // Цифры одной ширины: подпись не дёргается каждую секунду.
    final metaStyle = base.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget label = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: sessionLabel(session.state),
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: ' ·',
            style: TextStyle(color: p.muted),
          ),
        ],
      ),
      style: textStyle,
    );
    // «Ожидает» чего именно — пишет сам Claude Code в уведомлении.
    if (session.state == CodeSessionState.unknown) {
      label = Tooltip(
        message:
            'Нет свежих событий после перезапуска лаунчера. Откройте сессию в Claude, чтобы проверить задачу.',
        child: label,
      );
    } else if (session.message.isNotEmpty) {
      label = Tooltip(message: session.message, child: label);
    }

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          // Значок — по левому краю карточки, как линия над ним.
          SizedBox(
            width: _iconBox,
            child: Center(child: _StateIcon(state: session.state)),
          ),
          const SizedBox(width: _iconGap),
          label,
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: onOpen == null
                    ? ''
                    : session.link == null
                    // Сессию из терминала в приложении Claude не открыть.
                    ? 'Показать окно Claude'
                    : 'Открыть сессию в Claude',
                child: QuietTextButton(
                  label: session.name,
                  style: textStyle,
                  horizontalPadding: QuietTextButton.spaceWidth(
                    context,
                    textStyle,
                  ),
                  onTap: onOpen == null ? null : () => onOpen!(session),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (!working)
            Text(_clock(session.updatedAt), style: metaStyle)
          else ...[
            Text(
              formatElapsed(now.difference(session.startedAt)),
              style: metaStyle,
            ),
            if (session.tokens > 0) ...[
              Text(' · ', style: metaStyle),
              _TokenCount(tokens: session.tokens, style: metaStyle),
            ],
          ],
        ],
      ),
    );
  }
}

/// Токены: новое значение сменяет прежнее затуханием. Число и подпись меняются
/// по отдельности — пока растёт только число, «тыс. токенов» стоит на месте.
class _TokenCount extends StatelessWidget {
  const _TokenCount({required this.tokens, required this.style});

  final int tokens;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final (number, unit) = tokenParts(tokens);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FadingText(number, style: style),
        Text(' ', style: style),
        _FadingText(unit, style: style),
      ],
    );
  }
}

/// Текст, который при смене сначала гаснет, потом проявляется новым. Ширина
/// меняется плавно, поэтому соседи по строке не прыгают. Строка прижата к
/// правому краю — подстраивается левая сторона.
class _FadingText extends StatelessWidget {
  const _FadingText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  static const _duration = Duration(milliseconds: 400);

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: _duration,
    curve: Curves.easeInOut,
    alignment: Alignment.centerRight,
    child: AnimatedSwitcher(
      duration: _duration,
      // Прежний текст гаснет в первой половине, новый проявляется во второй.
      switchInCurve: const Interval(0.5, 1, curve: Curves.easeOut),
      switchOutCurve: const Interval(0.5, 1, curve: Curves.easeIn),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerRight,
        children: [...previous, ?current],
      ),
      child: Text(text, key: ValueKey(text), style: style),
    ),
  );
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final CodeSessionState state;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = sessionColor(p, state);
    final icon = switch (state) {
      CodeSessionState.unknown => Icon(
        AppIcons.unknown,
        size: 14,
        color: color,
      ),
      CodeSessionState.working => SizedBox.square(
        dimension: 11,
        child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
      ),
      CodeSessionState.needsPermission ||
      CodeSessionState.needsAnswer => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      CodeSessionState.done => Icon(AppIcons.check, size: 14, color: color),
    };
    // По центру строки значок выглядит выше слова: буквы сидят в строке ниже
    // середины. Опускаем к середине между центром заглавных и строчных;
    // галочка в своём квадрате и так стоит выше — её чуть сильнее.
    return Transform.translate(
      offset: Offset(0, state == CodeSessionState.done ? 1.5 : 1),
      child: icon,
    );
  }
}
