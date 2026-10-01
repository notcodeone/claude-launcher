import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Подтверждение в том же стиле: чёрная кнопка действия и «Отмена» без фона.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String text,
  required String confirmLabel,
  String? detail,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AppDialogFrame(
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 13.5),
          ),
          if (detail != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: context.palette.field,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                detail,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Отмена',
                  kind: AppButtonKind.secondary,
                  expand: true,
                  large: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppButton(
                  label: confirmLabel,
                  expand: true,
                  large: true,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Сетка вариантов выбора: 10 колонок на всю ширину. Ячейки 40×40 шире значков (24),
/// поэтому шаг считается по значкам — крайние значки стоят ровно по краям полей.
class ChoiceGrid extends StatelessWidget {
  const ChoiceGrid({super.key, required this.children});

  final List<Widget> children;

  static const _columns = 10;
  static const _cell = 40.0;
  static const _glyph = 24.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final step = (constraints.maxWidth - _glyph) / (_columns - 1);
        const inset = (_cell - _glyph) / 2;
        return Column(
          children: [
            for (var start = 0; start < children.length; start += _columns)
              SizedBox(
                height: _cell + 2,
                width: constraints.maxWidth,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (
                      var i = start;
                      i < children.length && i < start + _columns;
                      i++
                    )
                      Positioned(
                        left: (i - start) * step - inset,
                        top: 0,
                        width: _cell,
                        height: _cell,
                        child: children[i],
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Вариант выбора в круге 40×40: цвет — кольцом вокруг, иконка — серым кругом под ней,
/// как в выборе иконки проекта ChatGPT.
class ChoiceCircle extends StatelessWidget {
  const ChoiceCircle({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.ring = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  /// Выбор показывается кольцом (для цветов), иначе — заливкой (для иконок).
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      type: MaterialType.transparency,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: p.field,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !ring && selected ? p.field : Colors.transparent,
            border: Border.all(
              color: ring && selected ? p.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
