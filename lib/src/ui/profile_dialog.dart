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
      return _DialogFrame(
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

class _DialogFrame extends StatelessWidget {
  const _DialogFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 470),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
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

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.profile, required this.folderLabel});

  final Profile? profile;
  final String Function(String name) folderLabel;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _email = TextEditingController(text: widget.profile?.email);
  late final _note = TextEditingController(text: widget.profile?.note);
  late String _marker = widget.profile?.marker ?? Profile.defaultMarker;
  late String _icon = widget.profile?.icon ?? Profile.defaultIcon;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
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

    return Form(
      key: _formKey,
      child: _DialogFrame(
        children: [
          Row(
            children: [
              ProfileAvatar(marker: _marker, icon: _icon, size: 48),
              const SizedBox(width: 14),
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
                    TextFormField(
                      controller: _name,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Например, Рабочий',
                      ),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? 'Введите название'
                          : null,
                      onChanged: isNew ? (_) => setState(() {}) : null,
                      onFieldSubmitted: (_) => _submit(),
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
                    TextFormField(
                      controller: _email,
                      decoration: const InputDecoration(
                        hintText: 'ivan@example.com',
                      ),
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const FieldLabel('Заметка'),
          TextFormField(
            controller: _note,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Например, проекты компании',
            ),
          ),
          const SizedBox(height: 16),
          const FieldLabel('Метка'),
          Wrap(
            spacing: 2,
            runSpacing: 2,
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
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final MapEntry(key: key, value: icon)
                  in profileIcons.entries)
                _Selectable(
                  selected: key == _icon,
                  onTap: () => setState(() => _icon = key),
                  child: Icon(icon, size: 22, color: p.text),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            widget.folderLabel(_name.text.trim()),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
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
      ),
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
