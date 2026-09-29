import 'package:flutter/material.dart';

import '../profile.dart';

/// Что пользователь ввёл в диалоге профиля.
typedef ProfileDraft = ({String name, String email, String note, String marker});

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
    final isNew = widget.profile == null;
    return AlertDialog(
      title: Text(isNew ? 'Новый профиль' : 'Профиль'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  hintText: 'Например, Рабочий',
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Введите название' : null,
                onChanged: isNew ? (_) => setState(() {}) : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(
                  labelText: 'Аккаунт (почта)',
                  hintText: 'Для памяти: в какой аккаунт входить',
                ),
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Заметка'),
              ),
              const SizedBox(height: 16),
              Text('Метка', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final marker in Profile.markers)
                    ChoiceChip(
                      label: Text(marker, style: const TextStyle(fontSize: 18)),
                      selected: marker == _marker,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _marker = marker),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                widget.folderLabel(_name.text.trim()),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(isNew ? 'Создать' : 'Сохранить'),
        ),
      ],
    );
  }
}
