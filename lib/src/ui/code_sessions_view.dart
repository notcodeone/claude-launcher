import 'dart:math';

import 'package:flutter/material.dart';

import '../integrations/claude_code_sessions.dart';
import 'theme.dart';
import 'widgets.dart';

/// Цвет состояния сессии. Им же окрашена точка на кнопке «Показать окно»,
/// когда сессии на карточке свёрнуты.
Color sessionColor(Palette p, CodeSessionState state) => switch (state) {
  CodeSessionState.working => p.text,
  CodeSessionState.needsPermission => p.warning,
  CodeSessionState.needsAnswer => p.info,
  CodeSessionState.done => p.success,
};

String sessionLabel(CodeSessionState state) => switch (state) {
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
  if (count < 1000) return '$count ${_tokensWord(count)}';
  final thousands = count / 1000;
  if (thousands.round() < 1000) return '${_short(thousands)} тыс. токенов';
  return '${_short(count / 1000000)} млн токенов';
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
    if (session.message.isNotEmpty) {
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

/// Токены набегают к новому значению за секунду, а не перескакивают: в
/// переписку ответ попадает целиком, ступенькой. Новая задача — сразу с нуля.
class _TokenCount extends StatefulWidget {
  const _TokenCount({required this.tokens, required this.style});

  final int tokens;
  final TextStyle style;

  @override
  State<_TokenCount> createState() => _TokenCountState();
}

class _TokenCountState extends State<_TokenCount>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late int _from = widget.tokens;
  late int _to = widget.tokens;

  int get _value =>
      (_from + (_to - _from) * Curves.easeOutCubic.transform(_controller.value))
          .round();

  @override
  void didUpdateWidget(_TokenCount old) {
    super.didUpdateWidget(old);
    if (widget.tokens == _to) return;
    final shown = _value;
    _to = widget.tokens;
    if (_to < shown) {
      _from = _to;
      _controller.value = 1;
    } else {
      _from = shown;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (_, _) => Text(formatTokens(_value), style: widget.style),
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
