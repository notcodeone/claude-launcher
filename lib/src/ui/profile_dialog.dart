import 'package:flutter/material.dart';

import '../profile.dart';
import 'profile_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// Что пользователь ввёл в диалоге профиля.
typedef ProfileDraft = ({
  String name,
  String email,
  String note,
  String marker,
  String icon,
});

/// Диалог создания и редактирования профиля.
///
/// [folderLabel] — куда профиль пишет данные (для нового — будущая папка).
Future<ProfileDraft?> showProfileDialog(
  BuildContext context, {
  Profile? profile,
  required String Function(String name) folderLabel,
}) {
  return showDialog<ProfileDraft>(
    context: context,
    builder: (_) => _ProfileDialog(profile: profile, folderLabel: folderLabel),
  );
}

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

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.profile, required this.folderLabel});

  final Profile? profile;
  final String Function(String name) folderLabel;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _email = TextEditingController(text: widget.profile?.email);
  late final _note = TextEditingController(text: widget.profile?.note);
  late String _marker = widget.profile?.marker ?? Profile.defaultMarker;
  late String _icon = widget.profile?.icon ?? Profile.defaultIcon;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Введите название');
      return;
    }
    Navigator.of(context).pop<ProfileDraft>((
      name: _name.text.trim(),
      email: _email.text.trim(),
      note: _note.text.trim(),
      marker: _marker,
      icon: _icon,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final isNew = widget.profile == null;

    return AppDialogFrame(
      children: [
        Row(
          children: [
            ProfileAvatar(marker: _marker, icon: _icon, size: 48),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isNew ? 'Новый профиль' : 'Профиль',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Отдельный вход в Claude со своими сессиями.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FieldLabel('Название'),
                  AppTextField(
                    controller: _name,
                    autofocus: true,
                    hintText: 'Например, Рабочий',
                    errorText: _nameError,
                    // Перерисовка — для превью папки и чтобы убрать ошибку.
                    onChanged: (_) => setState(() => _nameError = null),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FieldLabel('Аккаунт'),
                  AppTextField(
                    controller: _email,
                    hintText: 'ivan@example.com',
                    onSubmitted: (_) => _submit(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const FieldLabel('Заметка'),
        AppTextField(
          controller: _note,
          minLines: 1,
          maxLines: 3,
          hintText: 'Например, проекты компании',
        ),
        const SizedBox(height: 16),
        const FieldLabel('Метка'),
        _OpticalGrid(
          children: [
            for (final marker in Profile.markers)
              _Selectable(
                selected: marker == _marker,
                ring: true,
                onTap: () => setState(() => _marker = marker),
                child: MarkerDot(marker: marker, size: 24),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _OpticalGrid(
          children: [
            for (final MapEntry(key: key, value: icon) in profileIcons.entries)
              _Selectable(
                selected: key == _icon,
                onTap: () => setState(() => _icon = key),
                child: Icon(icon, size: 24, color: p.text),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          widget.folderLabel(_name.text.trim()),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
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
                label: isNew ? 'Создать' : 'Сохранить',
                expand: true,
                large: true,
                onPressed: _submit,
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
class _OpticalGrid extends StatelessWidget {
  const _OpticalGrid({required this.children});

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
class _Selectable extends StatelessWidget {
  const _Selectable({
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
