import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Белая карточка на мягкой тени, без рамки.
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.cardBorder),
        boxShadow: p.softShadow,
      ),
      padding: padding,
      child: child,
    );
  }
}

enum AppButtonKind {
  /// Чёрная кнопка — главное действие.
  primary,

  /// Белая кнопка на тени.
  secondary,

  /// Просто текст, как «Вернуться в корзину».
  text,
}

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.icon,
    this.expand = false,
    this.compact = false,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final IconData? icon;
  final bool expand;
  final bool compact;

  /// Цвет текста для текстовой кнопки (например, красный для опасного действия).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null;
    final (background, foreground) = switch (kind) {
      AppButtonKind.primary =>
        enabled ? (p.primary, p.onPrimary) : (p.field, p.muted),
      AppButtonKind.secondary => (p.card, enabled ? p.text : p.muted),
      AppButtonKind.text => (
        Colors.transparent,
        enabled ? (color ?? p.text) : p.muted,
      ),
    };
    final radius = BorderRadius.circular(12);

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: compact ? 13.5 : 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: kind == AppButtonKind.secondary
            ? Border.all(color: p.cardBorder)
            : null,
        boxShadow: kind == AppButtonKind.secondary && enabled
            ? p.softShadow
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: foreground.withValues(alpha: 0.06),
          highlightColor: foreground.withValues(alpha: 0.08),
          splashColor: foreground.withValues(alpha: 0.10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 18,
              vertical: compact ? 9 : 12,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Чёрная квадратная кнопка в углу, как «+» в NotNotes.
class AppFab extends StatelessWidget {
  const AppFab({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(16);
    final button = Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: p.primary,
        borderRadius: radius,
        boxShadow: p.softShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: p.onPrimary.withValues(alpha: 0.08),
          child: Icon(icon, color: p.onPrimary, size: 26),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Цветной кружок метки профиля — как выбор цвета товара.
class MarkerDot extends StatelessWidget {
  const MarkerDot({super.key, required this.marker, this.size = 22});

  final String marker;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = markerColor(marker);
    // Светлый кружок на белом (и тёмный на тёмном) без обводки теряется.
    final needsOutline =
        (color.computeLuminance() - p.card.computeLuminance()).abs() < 0.2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: needsOutline ? Border.all(color: p.divider, width: 1.5) : null,
      ),
    );
  }
}

/// «● Открыт» — как «● В наличии».
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: p.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: p.success,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Подпись над полем: мелкие серые заглавные, как «E-MAIL» и «ФИО».
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

/// Спокойная серая плашка для подсказок, статуса и ошибок.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.text,
    this.error = false,
    this.progress = false,
    this.action,
  });

  final IconData icon;
  final String text;
  final bool error;
  final bool progress;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreground = error ? p.danger : p.text;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: error ? p.dangerSurface : p.field,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: error ? p.danger : p.muted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  text,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          if (progress) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(),
            ),
          ],
        ],
      ),
    );
  }
}

enum FaceMood {
  /// Закрытые глаза — «ничего нет».
  sleepy,

  /// Взгляд вверх и неуверенный рот — «что-то не так».
  worried,
}

/// Лицо-иллюстрация для пустых состояний, как в sensomni и NotNotes.
class FaceIllustration extends StatelessWidget {
  const FaceIllustration({super.key, required this.mood, this.size = 96});

  final FaceMood mood;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _FacePainter(mood, context.palette.text),
  );
}

class _FacePainter extends CustomPainter {
  _FacePainter(this.mood, this.color);

  final FaceMood mood;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.06;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final center = Offset(s / 2, s / 2);
    canvas.drawCircle(center, s / 2 - stroke / 2, paint);

    switch (mood) {
      case FaceMood.sleepy:
        for (final dx in [-0.18, 0.18]) {
          final eye = Rect.fromCenter(
            center: Offset(s * (0.5 + dx), s * 0.42),
            width: s * 0.2,
            height: s * 0.12,
          );
          canvas.drawArc(eye, 0.15, math.pi - 0.3, false, paint);
        }
        canvas.drawLine(
          Offset(s * 0.43, s * 0.7),
          Offset(s * 0.57, s * 0.7),
          paint,
        );
      case FaceMood.worried:
        final fill = Paint()..color = color;
        for (final dx in [-0.17, 0.17]) {
          canvas.drawCircle(Offset(s * (0.5 + dx), s * 0.42), s * 0.045, fill);
          final brow = Offset(s * (0.5 + dx), s * 0.29);
          canvas.drawLine(
            brow.translate(-s * 0.06, dx < 0 ? s * 0.02 : -s * 0.02),
            brow.translate(s * 0.06, dx < 0 ? -s * 0.02 : s * 0.02),
            paint,
          );
        }
        final mouth = Path()
          ..moveTo(s * 0.38, s * 0.7)
          ..quadraticBezierTo(s * 0.44, s * 0.65, s * 0.5, s * 0.69)
          ..quadraticBezierTo(s * 0.56, s * 0.73, s * 0.62, s * 0.67);
        canvas.drawPath(mouth, paint);
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.mood != mood || old.color != color;
}
