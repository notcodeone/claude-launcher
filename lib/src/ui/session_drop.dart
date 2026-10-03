import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../integrations/claude_code_sessions.dart';
import '../integrations/session_transfer.dart';
import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_dialog.dart';
import 'snackbar.dart';
import 'widgets.dart';

/// Сессию бросили на карточку профиля [target]: копируем — или, если при
/// броске зажат ⌥ (Alt на Windows), переносим. Профили, которые для этого надо
/// закрыть (цель — всегда, источник — при переносе), закрываются бережно
/// после вопроса и потом открываются снова. Итог — оповещение с «Отменить».
Future<void> dropSession(
  BuildContext context, {
  required LauncherController launcher,
  required CodeSession session,
  required Profile target,
}) async {
  final mode = HardwareKeyboard.instance.isAltPressed
      ? TransferMode.move
      : TransferMode.copy;
  final source = launcher.profiles
      .where((profile) => profile.id == session.profileId)
      .firstOrNull;
  if (source == null || source.id == target.id) return;

  final toClose = [
    if (launcher.isRunning(target)) target,
    if (mode == TransferMode.move && launcher.isRunning(source)) source,
  ];
  final verb = mode == TransferMode.move ? 'Перенести' : 'Скопировать';
  if (toClose.isNotEmpty) {
    final names = toClose.map((profile) => '«${profile.name}»').join(' и ');
    final ok = await showConfirmDialog(
      context,
      title: '$verb сессию в «${target.name}»?',
      text:
          '${toClose.length == 1 ? 'Профиль' : 'Профили'} $names '
          '${toClose.length == 1 ? 'закроется' : 'закроются'} '
          '${Platform.isMacOS ? 'так же, как по ⌘Q,' : 'как при обычном выходе,'} '
          'и сразу откроется снова: открытый Claude не видит новых сессий.',
      confirmLabel: 'Закрыть и ${verb.toLowerCase()}',
    );
    if (!ok) return;
    for (final profile in toClose) {
      await launcher.close(profile);
      if (launcher.isRunning(profile)) {
        AppSnackbar.show(
          Snack(
            id: 'transfer',
            icon: AppIcons.error,
            error: true,
            text: '«${profile.name}» не закрылся',
          ),
        );
        return;
      }
    }
  }

  final journal = Directory(
    p.join((await getApplicationSupportDirectory()).path, 'transfers'),
  );
  final transfer = SessionTransfer(journalRoot: journal);
  try {
    final record = await transfer.run(
      sessionId: session.hostSessionId,
      source: await launcher.transferSideOf(source),
      target: await launcher.transferSideOf(target),
      mode: mode,
    );
    AppSnackbar.show(
      Snack(
        id: 'transfer',
        icon: AppIcons.check,
        text: mode == TransferMode.move
            ? 'Сессия перенесена в «${target.name}»'
            : 'Сессия скопирована в «${target.name}»',
        action: 'Отменить',
        duration: const Duration(seconds: 10),
        onAction: () => _undo(transfer, record),
      ),
    );
  } on TransferRefused catch (refused) {
    AppSnackbar.show(
      Snack(
        id: 'transfer',
        icon: AppIcons.error,
        error: true,
        text: refused.message,
      ),
    );
  } catch (error) {
    debugPrint('Не удалось перенести сессию: $error');
    AppSnackbar.show(
      const Snack(
        id: 'transfer',
        icon: AppIcons.error,
        error: true,
        text: 'Не удалось перенести сессию',
      ),
    );
  } finally {
    // Закрытые ради переноса — снова открываем, как были.
    for (final profile in toClose.reversed) {
      await launcher.switchTo(profile);
    }
  }
}

Future<void> _undo(SessionTransfer transfer, TransferRecord record) async {
  try {
    await transfer.undo(record);
    AppSnackbar.show(
      const Snack(
        id: 'transfer',
        icon: AppIcons.check,
        text: 'Перенос отменён',
      ),
    );
  } on TransferRefused catch (refused) {
    AppSnackbar.show(
      Snack(
        id: 'transfer',
        icon: AppIcons.error,
        error: true,
        text: refused.message,
      ),
    );
  }
}
