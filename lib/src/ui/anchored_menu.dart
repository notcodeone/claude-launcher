import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Пункт меню.
class MenuEntry<T> {
  const MenuEntry({
    required this.value,
    required this.icon,
    required this.label,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
  });

  final T value;
  final IconData icon;
  final String label;

  /// Опасное действие: красный текст и иконка (и в неактивном виде).
  final bool destructive;
  final bool enabled;

  /// Отмечен галочкой — для выбора варианта.
  final bool selected;
}

/// Меню под элементом: экран плавно затемняется, сам элемент ([highlight] — его
/// копия на том же месте) остаётся поверх затемнения, меню — под ним с отступом,
/// по правому краю. Если снизу не хватает места — над элементом. [caption] —
/// пояснение над пунктами, не нажимается.
Future<T?> showAnchoredMenu<T>({
  required BuildContext anchorContext,
  required Widget highlight,
  List<MenuEntry<T>> entries = const [],
  Widget? caption,
  Widget? content,
  double maxWidth = 300,
}) {
  final navigator = Navigator.of(anchorContext);
  final overlayBox =
      navigator.overlay!.context.findRenderObject()! as RenderBox;
  final anchorBox = anchorContext.findRenderObject()! as RenderBox;
  final anchorRect =
      anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
      anchorBox.size;

  return navigator.push(
    _AnchoredMenuRoute<T>(
      anchorRect: anchorRect,
      highlight: highlight,
      entries: entries,
      caption: caption,
      content: content,
      maxWidth: maxWidth,
      scrim: anchorContext.palette.scrim,
      capturedThemes: InheritedTheme.capture(
        from: anchorContext,
        to: navigator.context,
      ),
    ),
  );
}

class _AnchoredMenuRoute<T> extends PopupRoute<T> {
  _AnchoredMenuRoute({
    required this.anchorRect,
    required this.highlight,
    required this.entries,
    required this.caption,
    required this.content,
    required this.maxWidth,
    required this.scrim,
    required this.capturedThemes,
  });

  final Rect anchorRect;
  final Widget highlight;
  final List<MenuEntry<T>> entries;
  final Widget? caption;
  final Widget? content;
  final double maxWidth;
  final Color scrim;
  final CapturedThemes capturedThemes;

  static const _gap = 8.0;

  @override
  Color get barrierColor => scrim;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Закрыть меню';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return capturedThemes.wrap(
      Stack(
        children: [
          // Копия элемента поверх затемнения. Клики проходят к барьеру и закрывают меню.
          Positioned.fromRect(
            rect: anchorRect,
            child: IgnorePointer(child: highlight),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _MenuLayout(anchorRect, _gap, maxWidth),
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(curved),
                  alignment: Alignment.topRight,
                  child: _MenuPanel<T>(
                    entries: entries,
                    caption: caption,
                    content: content,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor, this.gap, this.maxWidth);

  final Rect anchor;
  final double gap;
  final double maxWidth;

  static const _margin = 12.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: 220.clamp(0, constraints.maxWidth - _margin * 2).toDouble(),
        maxWidth: maxWidth
            .clamp(0, constraints.maxWidth - _margin * 2)
            .toDouble(),
        maxHeight: constraints.maxHeight - _margin * 2,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (anchor.right - childSize.width).clamp(
      _margin,
      size.width - childSize.width - _margin,
    );
    final below = anchor.bottom + gap;
    final fitsBelow = below + childSize.height <= size.height - _margin;
    final y = fitsBelow ? below : anchor.top - gap - childSize.height;
    return Offset(
      x,
      y.clamp(_margin, size.height - childSize.height - _margin),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.anchor != anchor || old.gap != gap || old.maxWidth != maxWidth;
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({required this.entries, this.caption, this.content});

  final List<MenuEntry<T>> entries;
  final Widget? caption;
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(16);
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: p.cardBorder),
      ),
      child: Material(
        color: p.card,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child:
            content ??
            IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (caption case final caption?) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: caption,
                    ),
                    const Divider(),
                  ],
                  for (final (index, entry) in entries.indexed) ...[
                    if (index > 0) const Divider(),
                    _MenuItem(entry: entry),
                  ],
                ],
              ),
            ),
      ),
    );
  }
}

class _MenuItem<T> extends StatelessWidget {
  const _MenuItem({required this.entry});

  final MenuEntry<T> entry;

  @override
  Widget build(BuildContext context) => AnchoredMenuAction(
    icon: entry.icon,
    label: entry.label,
    destructive: entry.destructive,
    selected: entry.selected,
    onPressed: entry.enabled
        ? () => Navigator.of(context).pop(entry.value)
        : null,
  );
}

/// Та же строка действия для меню с произвольным содержимым.
class AnchoredMenuAction extends StatelessWidget {
  const AnchoredMenuAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.selected = false,
    this.loading = false,
    this.backgroundColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool selected;
  final bool loading;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = destructive ? p.danger : p.text;
    final item = InkWell(
      onTap: onPressed,
      hoverColor: p.field,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (loading)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: TextStyle(color: color, fontSize: 14)),
            ),
            if (selected) ...[
              const SizedBox(width: 16),
              Icon(AppIcons.check, size: 16, color: color),
            ],
          ],
        ),
      ),
    );
    // Неактивный пункт сохраняет свой цвет (у опасного — красный), но приглушён.
    final enabled = onPressed != null || loading;
    final row = enabled ? item : Opacity(opacity: 0.4, child: item);
    return backgroundColor == null
        ? row
        : Material(color: backgroundColor!, child: row);
  }
}
