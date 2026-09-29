import 'package:flutter/material.dart';

import '../profile.dart';
import 'theme.dart';
import 'widgets.dart';

/// Что пользователь ввёл в диалоге профиля.
typedef ProfileDraft = ({
  String name,
  String email,
  String note,
  String marker,
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

/// Подтверждение в том же стиле: чёрная кнопка действия и текстовая «Отмена».
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
          AppButton(
            label: confirmLabel,
            expand: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 4),
          AppButton(
            label: 'Отмена',
            kind: AppButtonKind.text,
            expand: true,
            onPressed: () => Navigator.of(context).pop(false),
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
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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
          Text(
            isNew ? 'Новый профиль' : 'Профиль',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Отдельный вход в Claude со своими сессиями.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 22),
          const FieldLabel('Название'),
          TextFormField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Например, Рабочий'),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Введите название' : null,
            onChanged: isNew ? (_) => setState(() {}) : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          const FieldLabel('Аккаунт'),
          TextFormField(
            controller: _email,
            decoration: const InputDecoration(hintText: 'ivan@example.com'),
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          const FieldLabel('Заметка'),
          TextFormField(
            controller: _note,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Например, проекты компании',
            ),
          ),
          const SizedBox(height: 14),
          const FieldLabel('Метка'),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final marker in Profile.markers)
                _Swatch(
                  marker: marker,
                  selected: marker == _marker,
                  onTap: () => setState(() => _marker = marker),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            widget.folderLabel(_name.text.trim()),
            style: theme.textTheme.bodySmall?.copyWith(color: p.muted),
          ),
          const SizedBox(height: 22),
          AppButton(
            label: isNew ? 'Создать' : 'Сохранить',
            expand: true,
            onPressed: _submit,
          ),
          const SizedBox(height: 4),
          AppButton(
            label: 'Отмена',
            kind: AppButtonKind.text,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Кружок цвета с кольцом выбора, как выбор цвета товара.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.marker,
    required this.selected,
    required this.onTap,
  });

  final String marker;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? p.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: MarkerDot(marker: marker, size: 24),
      ),
    );
  }
}
