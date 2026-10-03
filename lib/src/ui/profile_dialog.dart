import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../integrations/profile_claude_code.dart';

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

/// Перенос профиля в свою папку Claude Code: переписка его сессий
/// копируется сама, а память проектов — общая, её пользователь выбирает.
/// Возвращает папки проектов, чью память взять; `null` — отменили.
Future<Set<String>?> showClaudeCodeMigrationDialog(
  BuildContext context, {
  required String profileName,
  required ClaudeCodeMigrationPlan plan,
}) => showDialog<Set<String>>(
  context: context,
  builder: (context) => _MigrationDialog(profileName: profileName, plan: plan),
);

class _MigrationDialog extends StatefulWidget {
  const _MigrationDialog({required this.profileName, required this.plan});

  final String profileName;
  final ClaudeCodeMigrationPlan plan;

  @override
  State<_MigrationDialog> createState() => _MigrationDialogState();
}

class _MigrationDialogState extends State<_MigrationDialog> {
  late final _withMemory = [
    for (final project in widget.plan.projects)
      if (project.hasMemory) project,
  ];
  late final _chosen = {for (final project in _withMemory) project.folder};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.plan.transcripts.length;
    return AppDialogFrame(
      children: [
        Text(
          'Своя память для «${widget.profileName}»',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${count == 0 ? 'Переписки сессий этого профиля в общей папке нет.' : 'Переписка сессий профиля ($count) скопируется в его папку.'}'
          '${_withMemory.isEmpty ? '' : ' Память проектов общая — отметьте, какую взять в профиль.'}'
          ' В «Основном» всё останется как было.',
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 13.5),
        ),
        if (_withMemory.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final project in _withMemory)
            CheckboxListTile(
              value: _chosen.contains(project.folder),
              onChanged: (value) => setState(
                () => value == true
                    ? _chosen.add(project.folder)
                    : _chosen.remove(project.folder),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(p.basename(project.cwd)),
              subtitle: Text(
                project.cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppButton(
                label: 'Перенести',
                expand: true,
                large: true,
                onPressed: () => Navigator.of(context).pop({..._chosen}),
              ),
            ),
          ],
        ),
      ],
    );
  }
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
