import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'profile_icons.dart';
import 'theme.dart';

/// Белая карточка на мягкой тени, без рамки.
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: borderRadius,
        boxShadow: p.softShadow,
      ),
      // Рамка поверх содержимого, а не вокруг: не меняет размеры (нужна только в тёмной теме).
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(color: p.cardBorder),
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Размеры кнопок и таблеток: одинаковая высота у всех видов.
const _buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 10);
const _buttonTextStyle = TextStyle(
  fontSize: 13.5,
  fontWeight: FontWeight.w500,
  height: 1.2,
);

enum AppButtonKind {
  /// Чёрная кнопка — главное действие.
  primary,

  /// Без фона и тени, как «Вернуться в корзину»; фон появляется только при наведении.
  secondary,

  /// Рискованное действие: красный текст на розовой подложке, как плашки ошибок.
  danger,
}

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.expand = false,
    this.large = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final bool expand;

  /// Крупная кнопка на всю ширину — для диалогов, как «Войти» в sensomni.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null;
    final (background, foreground) = switch (kind) {
      AppButtonKind.primary =>
        enabled ? (p.primary, p.onPrimary) : (p.field, p.muted),
      AppButtonKind.secondary => (
        Colors.transparent,
        enabled ? p.text : p.muted,
      ),
      AppButtonKind.danger => (p.dangerSurface, enabled ? p.danger : p.muted),
    };
    return _Pressable(
      background: background,
      foreground: foreground,
      hover: kind == AppButtonKind.secondary ? p.field : null,
      onTap: onPressed,
      child: Padding(
        padding: large
            ? const EdgeInsets.symmetric(horizontal: 18, vertical: 13)
            : _buttonPadding,
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: _buttonTextStyle.copyWith(
                color: foreground,
                fontSize: large ? 14.5 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Скруглённая нажимаемая поверхность. Подсветка занимает всю площадь —
/// без светлой каймы по краю.
class _Pressable extends StatelessWidget {
  const _Pressable({
    required this.background,
    required this.foreground,
    required this.onTap,
    required this.child,
    this.hover,
  });

  final Color background;
  final Color foreground;
  final VoidCallback? onTap;
  final Widget child;

  /// Цвет фона при наведении; по умолчанию — лёгкий оттенок цвета текста.
  final Color? hover;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: hover ?? foreground.withValues(alpha: 0.07),
        highlightColor: foreground.withValues(alpha: 0.08),
        splashColor: foreground.withValues(alpha: 0.10),
        child: child,
      ),
    );
  }
}

/// Круглая кнопка-иконка без фона (фон — только при наведении).
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 36,
    this.badge,
    this.loading = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  /// Цветная точка справа сверху от значка.
  final Color? badge;

  /// Вместо значка — индикатор загрузки: действие кнопки уже идёт.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final button = Material(
      type: MaterialType.transparency,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        hoverColor: p.field,
        highlightColor: p.text.withValues(alpha: 0.08),
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: loading
                    ? SizedBox.square(
                        key: const ValueKey('loading'),
                        dimension: size * 0.44,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.text,
                        ),
                      )
                    : Icon(
                        icon,
                        key: ValueKey(icon),
                        size: size * 0.55,
                        color: onPressed == null
                            ? p.muted.withValues(alpha: 0.5)
                            : p.text,
                      ),
              ),
              Positioned(
                top: size * 0.14,
                right: size * 0.14,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: badge == null || loading
                      ? const SizedBox.square(dimension: 9)
                      // Обводка цветом карточки отделяет точку от значка.
                      : Container(
                          key: ValueKey(badge),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: badge,
                            shape: BoxShape.circle,
                            border: Border.all(color: p.card, width: 1.5),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Текст-кнопка без фона: при наведении — серая скруглённая подложка.
/// Отступы по бокам [horizontalPadding] — обычно в ширину пробела, чтобы
/// кнопка читалась как слово во фразе.
class QuietTextButton extends StatelessWidget {
  const QuietTextButton({
    super.key,
    required this.label,
    required this.style,
    required this.horizontalPadding,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final double horizontalPadding;
  final VoidCallback? onTap;

  /// Ширина пробела в [style] — для [horizontalPadding].
  static double spaceWidth(BuildContext context, TextStyle style) =>
      (TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout()).width;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: p.field,
        highlightColor: p.text.withValues(alpha: 0.08),
        splashColor: p.text.withValues(alpha: 0.10),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 3,
          ),
          child: Text(
            label,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Чёрная кнопка в углу, как «+» в NotNotes, но с подписью.
class AppFab extends StatelessWidget {
  const AppFab({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(16);
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: p.softShadow),
      child: Material(
        color: p.primary,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          hoverColor: p.onPrimary.withValues(alpha: 0.08),
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.only(left: 18, right: 22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: p.onPrimary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: p.onPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Поле ввода: серая заливка без рамки; при фокусе плавно становится белым
/// с рамкой 2 px. Рамка есть всегда (в цвет заливки), чтобы текст не прыгал.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.errorText,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? hintText;

  /// Текст ошибки под полем; пока он задан, рамка красная.
  final String? errorText;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final focused = _focus.hasFocus;
    final error = widget.errorText;
    final borderColor = error != null
        ? p.danger
        : focused
        ? p.primary
        : p.field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: focused ? p.card : p.field,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            style: TextStyle(color: p.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: TextStyle(color: p.muted),
              filled: false,
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              // На 2 px меньше прежних отступов — столько занимает рамка.
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(error, style: TextStyle(color: p.danger, fontSize: 12)),
          ),
      ],
    );
  }
}

/// Цветной кружок метки — как выбор цвета товара.
class MarkerDot extends StatelessWidget {
  const MarkerDot({super.key, required this.marker, this.size = 22});

  final String marker;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = markerColor(marker);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: _blendsIn(color, p.card)
            ? Border.all(color: p.divider, width: 1.5)
            : null,
      ),
    );
  }
}

/// Аватар профиля: кружок цвета метки с иконкой профиля.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.marker,
    required this.icon,
    this.size = 40,
  });

  final String marker;
  final String icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = markerColor(marker);
    // На жёлтом и белом белая иконка не читается.
    final iconColor = color.computeLuminance() > 0.5
        ? const Color(0xFF0A0A0A)
        : Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: _blendsIn(color, p.card)
            ? Border.all(color: p.divider, width: 1.5)
            : null,
      ),
      child: Icon(profileIcon(icon), size: size * 0.5, color: iconColor),
    );
  }
}

/// Светлый кружок на белом (и тёмный на тёмном) без обводки теряется.
bool _blendsIn(Color color, Color background) =>
    (color.computeLuminance() - background.computeLuminance()).abs() < 0.2;

/// Маленькая серая метка рядом с названием, например «По умолчанию».
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: p.muted),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: p.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// «● Открыт» — как «● В наличии».
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.label, this.color});

  final String label;

  /// Цвет точки и подписи; по умолчанию — зелёный «всё хорошо».
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.palette.success;
    // Длинная подпись переносится, а не обрезается краем окна; точка — у
    // первой строки.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(top: 5.5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
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
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

/// Общая рамка диалогов: ширина до 470, поля 24, прокрутка, если не влезает.
class AppDialogFrame extends StatelessWidget {
  const AppDialogFrame({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 470),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Строка настройки: заголовок, пояснение, необязательная ссылка и переключатель.
class SettingSwitchRow extends StatelessWidget {
  const SettingSwitchRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.link,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(description, style: theme.textTheme.bodySmall),
              if (link != null) ...[const SizedBox(height: 8), link!],
            ],
          ),
        ),
        const SizedBox(width: 16),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Подсветка под курсором и при нажатии — как у карточек профилей: едва
/// заметная заливка цветом текста, без волны. Своя, на MouseRegion: подсветка
/// InkWell в меню оставалась, когда курсор уже ушёл или пункт стал неактивным.
class HoverSurface extends StatefulWidget {
  const HoverSurface({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  /// Те же доли цвета текста, что у карточек профилей (HomePage).
  static const hoverAlpha = 0.018;
  static const pressedAlpha = 0.03;

  @override
  State<HoverSurface> createState() => _HoverSurfaceState();
}

class _HoverSurfaceState extends State<HoverSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  void didUpdateWidget(HoverSurface old) {
    super.didUpdateWidget(old);
    // Пункт стал неактивным (идёт действие) — нажатия больше нет.
    if (widget.onTap == null) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onTap != null;
    final alpha = !enabled
        ? 0.0
        : _pressed
        ? HoverSurface.pressedAlpha
        : _hovered
        ? HoverSurface.hoverAlpha
        : 0.0;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: p.text.withValues(alpha: alpha),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Ссылка в тексте: цвета текста, при наведении подчёркивается.
class InlineLink extends StatefulWidget {
  const InlineLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<InlineLink> createState() => _InlineLinkState();
}

class _InlineLinkState extends State<InlineLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: p.text,
            fontWeight: FontWeight.w500,
            decoration: _hovered ? TextDecoration.underline : null,
          ),
        ),
      ),
    );
  }
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
    this.footer,
    this.onClose,
  });

  final IconData icon;
  final String text;
  final bool error;
  final bool progress;

  /// Кнопка справа от текста.
  final Widget? action;

  /// Ряд кнопок под текстом — когда их несколько.
  final Widget? footer;

  /// Крестик справа: подсказку можно закрыть.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreground = error ? p.danger : p.text;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      // Как у карточек — 16 со всех сторон.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: error ? p.dangerSurface : p.field,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: error ? p.danger : p.muted),
              const SizedBox(width: 12),
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
              // Текст кнопки — по тому же краю, что значки в карточках: у кнопки
              // свои 16 px отступа, поэтому сдвигаем её к краю плашки.
              if (action != null)
                Transform.translate(offset: const Offset(16, 0), child: action),
              // Крестик — по краю значков в карточках: у кнопки 8 px вокруг значка.
              if (onClose != null)
                Transform.translate(
                  offset: const Offset(8, 0),
                  child: CircleIconButton(
                    icon: AppIcons.close,
                    tooltip: 'Закрыть',
                    onPressed: onClose,
                  ),
                ),
            ],
          ),
          if (progress) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(),
            ),
          ],
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}

/// Иконки интерфейса — Lucide, в том же стиле, что и иконки профилей.
abstract final class AppIcons {
  static const add = LucideIcons.plus;
  static const more = LucideIcons.ellipsisVertical;
  static const launch = LucideIcons.play;
  static const show = LucideIcons.eye;
  static const charts = LucideIcons.chartColumn;
  static const edit = LucideIcons.pencil;
  static const folder = LucideIcons.folderOpen;
  static const remove = LucideIcons.trash2;
  static const info = LucideIcons.info;
  static const error = LucideIcons.circleAlert;
  static const unknown = LucideIcons.circleHelp;
  static const sync = LucideIcons.refreshCw;
  static const download = LucideIcons.download;
  static const hand = LucideIcons.hand;
  static const check = LucideIcons.check;
  static const themeSystem = LucideIcons.sunMoon;
  static const themeLight = LucideIcons.sun;
  static const themeDark = LucideIcons.moon;
  static const settings = LucideIcons.settings;
  static const back = LucideIcons.arrowLeft;
  static const chevron = LucideIcons.chevronRight;
  static const general = LucideIcons.slidersHorizontal;
  static const claudeCode = LucideIcons.squareTerminal;
  static const updates = LucideIcons.refreshCw;
  static const experiments = LucideIcons.flaskConical;
  static const quit = LucideIcons.power;
  static const location = LucideIcons.mapPin;
  static const shield = LucideIcons.shieldCheck;
  static const shieldAlert = LucideIcons.shieldAlert;
  static const locationOff = LucideIcons.mapPinOff;

  /// Открывать при запуске лаунчера — та же иконка, что у кнопки запуска профиля.
  static const startup = launch;
  static const startupOff = LucideIcons.playOff;
  static const close = LucideIcons.x;
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
