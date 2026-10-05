import 'dart:io';

import 'package:flutter/services.dart';
import 'package:win32/win32.dart' show WindowsException;
import 'package:win32_registry/win32_registry.dart';

/// Обработчик ссылок `claude://` в системе (см. `ClaudeLinkHandler`).
abstract class LinkHandlerPlatform {
  /// Кто сейчас открывает ссылки; равен [ownId] — лаунчер.
  Future<String?> currentHandler();

  Future<String?> ownId();

  /// Сделать лаунчер обработчиком.
  Future<void> claim();

  /// Вернуть роль [previous] (прежний [currentHandler]) — только если она
  /// сейчас у лаунчера; `null` — как было без лаунчера.
  Future<void> restore(String? previous);

  /// Выбор пользователя, который перекрывает регистрацию лаунчера и который
  /// программа изменить не может; `null` — такого нет.
  Future<String?> blocker();

  /// Ссылки, которые система уже отдала лаунчеру и которые он ещё не забрал.
  Future<List<String>> takeLinks();

  /// Своя схема `claudelauncher://` для ярлыков профилей. macOS берёт её из
  /// Info.plist, Windows — из реестра. Остаётся и после выхода: ярлык должен
  /// запускать закрытый лаунчер; убирает её только [removeShortcuts].
  Future<void> registerShortcuts();

  /// Удаление лаунчера (`--cleanup`).
  Future<void> removeShortcuts();

  static LinkHandlerPlatform? forCurrentPlatform() {
    if (Platform.isMacOS) return const MacLinkHandlerPlatform();
    if (Platform.isWindows) return WindowsLinkHandlerPlatform();
    return null;
  }
}

/// macOS: LaunchServices через нативную часть (MainFlutterWindow.swift);
/// ссылку macOS присылает событием `open-url` в AppDelegate.
class MacLinkHandlerPlatform implements LinkHandlerPlatform {
  const MacLinkHandlerPlatform();

  static const claudeBundleId = 'com.anthropic.claudefordesktop';
  static const _channel = MethodChannel('claude_launcher/native');

  @override
  Future<String?> currentHandler() =>
      _channel.invokeMethod<String>('linkHandler');

  @override
  Future<String?> ownId() => _channel.invokeMethod<String>('ownBundleId');

  @override
  Future<void> claim() async {
    final own = await ownId();
    if (own != null) await _channel.invokeMethod<bool>('setLinkHandler', own);
  }

  @override
  Future<void> restore(String? previous) async {
    final own = await ownId();
    if (own == null || await currentHandler() != own) return;
    await _channel.invokeMethod<bool>(
      'setLinkHandler',
      previous ?? claudeBundleId,
    );
  }

  @override
  Future<String?> blocker() async => null;

  @override
  Future<List<String>> takeLinks() async =>
      (await _channel.invokeListMethod<String>('takeLinks')) ?? const [];

  @override
  Future<void> registerShortcuts() async {}

  @override
  Future<void> removeShortcuts() async {}
}

/// Windows: регистрация в реестре пользователя, как у claude-profile-manager.
///
/// - `Software\Classes\claude` — команда лаунчера: её Windows берёт, пока в
///   «Приложениях по умолчанию» для `claude` ничего не выбрано. Claude (не из
///   Microsoft Store) при каждом запуске пишет сюда свою — её запоминаем.
/// - ProgID `ClaudeLauncher.claude` и `Capabilities` с `RegisteredApplications`
///   — чтобы лаунчер был в «Приложениях по умолчанию».
/// - `UrlAssociations\claude\UserChoice` — выбор пользователя. Он защищён
///   подписью Windows, программа его не меняет: если там Claude, ссылки идут
///   ему, пока пользователь сам не выберет лаунчер ([blocker]).
///
/// Ссылку Windows передаёт командой `"лаунчер" --open-url "<ссылка>"`; если
/// лаунчер уже запущен, новый процесс передаёт её ему (windows/runner/main.cpp).
class WindowsLinkHandlerPlatform implements LinkHandlerPlatform {
  WindowsLinkHandlerPlatform({String? exe})
    : exe = exe ?? Platform.resolvedExecutable;

  final String exe;

  static const progId = 'ClaudeLauncher.claude';
  static const _scheme = r'Software\Classes\claude';
  static const _shortcutScheme = r'Software\Classes\claudelauncher';
  static const _progIdKey = r'Software\Classes\' + progId;
  static const _capabilities = r'Software\ClaudeLauncher\Capabilities';
  static const _registered = r'Software\RegisteredApplications';
  static const _userChoice =
      r'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude\UserChoice';

  /// Метка прежнего обработчика — выбора в «Приложениях по умолчанию».
  static const _choicePrefix = 'progid:';

  String get command => '"$exe" --open-url "%1"';

  String? _read(String path, String name) {
    try {
      final key = CURRENT_USER.open(path);
      try {
        return key.getString(name);
      } finally {
        key.close();
      }
    } on WindowsException {
      return null;
    }
  }

  @override
  Future<String?> currentHandler() async {
    final choice = _read(_userChoice, 'ProgId');
    if (choice != null) {
      return choice == progId ? command : '$_choicePrefix$choice';
    }
    return _read('$_scheme\\shell\\open\\command', '');
  }

  @override
  Future<String?> ownId() async => command;

  void _writeProtocol(String path, String commandLine) {
    final key = CURRENT_USER.create(path);
    try {
      key.setValue('', const RegistryValue.string('URL:Claude'));
      key.setValue('URL Protocol', const RegistryValue.string(''));
    } finally {
      key.close();
    }
    final icon = CURRENT_USER.create('$path\\DefaultIcon');
    try {
      icon.setValue('', RegistryValue.string('"$exe",0'));
    } finally {
      icon.close();
    }
    final open = CURRENT_USER.create('$path\\shell\\open\\command');
    try {
      open.setValue('', RegistryValue.string(commandLine));
    } finally {
      open.close();
    }
  }

  void _setString(String path, String name, String value) {
    final key = CURRENT_USER.create(path);
    try {
      if (key.getString(name) != value) {
        key.setValue(name, RegistryValue.string(value));
      }
    } finally {
      key.close();
    }
  }

  @override
  Future<void> claim() async {
    _writeProtocol(_progIdKey, command);
    _setString(_capabilities, 'ApplicationName', 'ClaudeLauncher');
    _setString(
      _capabilities,
      'ApplicationDescription',
      'Открывает ссылки Claude в нужном профиле',
    );
    _setString('$_capabilities\\URLAssociations', 'claude', progId);
    _setString(_registered, 'ClaudeLauncher', _capabilities);
    if (_read('$_scheme\\shell\\open\\command', '') != command) {
      _writeProtocol(_scheme, command);
    }
  }

  void _removeTree(String path) {
    try {
      final key = CURRENT_USER.open(
        path,
        config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
      );
      try {
        key.removeTree();
      } finally {
        key.close();
      }
    } on WindowsException {
      // Нет — и не надо.
    }
    try {
      final parent = path.substring(0, path.lastIndexOf(r'\'));
      final name = path.substring(path.lastIndexOf(r'\') + 1);
      final key = CURRENT_USER.open(
        parent,
        config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
      );
      try {
        key.removeSubkey(name);
      } finally {
        key.close();
      }
    } on WindowsException {
      // Уже удалён.
    }
  }

  @override
  Future<void> removeShortcuts() async => _removeTree(_shortcutScheme);

  @override
  Future<void> registerShortcuts() async {
    if (_read('$_shortcutScheme\\shell\\open\\command', '') != command) {
      _writeProtocol(_shortcutScheme, command);
    }
  }

  @override
  Future<void> restore(String? previous) async {
    // Своё убираем всегда: иначе лаунчер остался бы в «Приложениях по
    // умолчанию» и после удаления.
    _removeTree(_progIdKey);
    _removeTree(r'Software\ClaudeLauncher');
    try {
      final key = CURRENT_USER.open(
        _registered,
        config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
      );
      try {
        key.removeValue('ClaudeLauncher');
      } finally {
        key.close();
      }
    } on WindowsException {
      // Не регистрировались.
    }
    // `claude` — только если там наша команда: чужую не трогаем.
    if (_read('$_scheme\\shell\\open\\command', '') != command) return;
    if (previous != null && !previous.startsWith(_choicePrefix)) {
      _writeProtocol(_scheme, previous);
    } else {
      _removeTree(_scheme);
    }
  }

  @override
  Future<String?> blocker() async {
    final choice = _read(_userChoice, 'ProgId');
    return choice != null && choice != progId ? choice : null;
  }

  /// Ссылки приходят аргументом запуска и от второго запуска (`openUrl`).
  @override
  Future<List<String>> takeLinks() async => const [];
}
