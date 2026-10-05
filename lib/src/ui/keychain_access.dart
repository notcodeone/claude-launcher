import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../integrations/live_usage.dart';
import 'snackbar.dart';
import 'theme.dart';
import 'widgets.dart';

/// Метка разрешения. macOS привязывает «Всегда разрешать» к требованию подписи,
/// а оно у нас — по сертификату (tool/sign_macos.sh), не по версии: пока
/// сертификат тот же, разрешение переживает обновления. Сменили сертификат —
/// меняем метку, и лаунчер попросит разрешить снова, а не macOS — без окна.
const keychainGrant = 'NotCode Code Signing 42ce8c7d';

/// macOS: доступ к «Claude Safe Storage» для свежих лимитов ещё не дан.
bool needsKeychainAccess(AppSettings settings) =>
    Platform.isMacOS && settings.keychainAccessVersion != keychainGrant;

/// Окно перед вопросом macOS: зачем лаунчеру пароль и что нажать. Только после
/// «Разрешить» лаунчер обращается к Связке ключей — вопрос macOS не появляется
/// без объяснения. true — доступ получен.
Future<bool> askKeychainAccess(
  BuildContext context, {
  required LiveUsage live,
  required AppSettings settings,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final p = context.palette;
      Widget step(String number, String text) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.field, shape: BoxShape.circle),
              child: Text(
                number,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
              ),
            ),
          ],
        ),
      );
      return AppDialogFrame(
        children: [
          Text('Свежие лимиты', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Чтобы показывать лимиты без задержки, лаунчер спрашивает их у '
            'Anthropic тем же запросом, что и сам Claude, — со входом профиля. '
            'Вход Claude зашифрован ключом в Связке ключей, поэтому macOS '
            'попросит разрешения. Ключ хранится только в памяти лаунчера.',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 13.5),
          ),
          step(
            '1',
            'macOS спросит пароль от вашей учётной записи Mac — введите его.',
          ),
          step('2', 'Нажмите «Всегда разрешать» — тогда вопрос не повторится.'),
          const SizedBox(height: 10),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Без свежих лимитов',
                  kind: AppButtonKind.secondary,
                  expand: true,
                  large: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppButton(
                  label: 'Разрешить',
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
  if (confirmed != true) return false;
  final granted = await live.unlock();
  if (granted) {
    await settings.setKeychainAccessVersion(keychainGrant);
    AppSnackbar.show(
      const Snack(
        id: 'keychain',
        icon: AppIcons.check,
        text: 'Доступ дан — лимиты будут свежими',
      ),
    );
  } else {
    AppSnackbar.show(
      const Snack(
        id: 'keychain',
        icon: AppIcons.error,
        error: true,
        text: 'macOS не дала доступ — лимиты из файлов Claude',
      ),
    );
  }
  return granted;
}
