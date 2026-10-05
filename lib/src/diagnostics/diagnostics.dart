import 'dart:io';

import '../app_settings.dart';
import '../integrations/claude_code_integration.dart';
import '../integrations/claude_links.dart';
import '../integrations/session_overview.dart';
import '../launcher_controller.dart';
import '../location/cowork_firewall.dart';
import '../location/egress_config.dart';
import '../location/kill_switch.dart';
import '../profile.dart';

enum CheckStatus { ok, info, warning, problem }

/// Итог одной проверки: что проверяли, как обстоят дела и — если лаунчер
/// может — как исправить одной кнопкой.
class DiagnosticCheck {
  const DiagnosticCheck(
    this.title,
    this.status,
    this.detail, {
    this.fixLabel,
    this.fix,
  });

  final String title;
  final CheckStatus status;
  final String detail;
  final String? fixLabel;
  final Future<void> Function()? fix;
}

/// «Настройки → Диагностика»: всё, что обычно ломается у профилей, одним
/// списком. Отчёт ([report]) — для присылки автору: без путей, почты и id
/// сессий (имена профилей остаются — без них отчёт не прочитать).
class Diagnostics {
  Diagnostics({
    required this.launcher,
    required this.settings,
    this.claudeCode,
    this.links,
    this.killSwitch,
    this.coworkFirewall,
    Future<List<ProfileSessions>> Function()? readSessions,
    this.config = const EgressConfig(),
    this.openDefaultApps,
  }) : readSessions = readSessions ?? (() => SessionOverview.read(launcher));

  final LauncherController launcher;
  final AppSettings settings;
  final ClaudeCodeIntegration? claudeCode;
  final ClaudeLinkHandler? links;
  final KillSwitch? killSwitch;
  final CoworkFirewall? coworkFirewall;
  final Future<List<ProfileSessions>> Function() readSessions;
  final EgressConfig config;

  /// Windows: открыть «Приложения по умолчанию» (выбор там меняет только
  /// пользователь).
  final Future<void> Function()? openDefaultApps;

  String? claudeVersion;

  Future<List<DiagnosticCheck>> run() async => [
    await _claude(),
    ..._profiles(),
    if (claudeCode != null) await _events(claudeCode!),
    if (links != null) await _links(links!),
    if (settings.killSwitch) await _killSwitch(),
    if (settings.parallelLaunch) await _updateHold(),
    if (coworkFirewall case final firewall? when settings.killSwitch)
      _cowork(firewall),
    await _sessions(),
  ];

  Future<DiagnosticCheck> _claude() async {
    final path = await launcher.host.locate();
    if (path == null) {
      return const DiagnosticCheck(
        'Claude',
        CheckStatus.problem,
        'Приложение Claude не найдено — установите Claude Desktop.',
      );
    }
    claudeVersion = await launcher.host.installedVersion();
    return DiagnosticCheck(
      'Claude',
      CheckStatus.ok,
      claudeVersion == null
          ? 'Установлен'
          : 'Установлен, версия $claudeVersion',
    );
  }

  Iterable<DiagnosticCheck> _profiles() sync* {
    var problems = false;
    for (final profile in launcher.profiles) {
      final dir = launcher.dataDirOf(profile);
      if (profile.lastLaunchedAt != null && !Directory(dir).existsSync()) {
        problems = true;
        yield DiagnosticCheck(
          'Профиль «${profile.name}»',
          CheckStatus.warning,
          'Папка профиля пропала — вход и сессии придётся настроить заново, '
              'если её не вернуть из Корзины или резервной копии.',
        );
      }
      final processes = launcher.instances
          .where((i) => launcher.host.samePath(launcher.host.dataDirOf(i), dir))
          .length;
      if (processes > 1) {
        problems = true;
        yield DiagnosticCheck(
          'Профиль «${profile.name}»',
          CheckStatus.warning,
          'Открыто $processes экземпляра Claude с одной папкой — закройте '
              'лишние, иначе Claude может испортить свои файлы.',
        );
      }
    }
    if (!problems) {
      final open = launcher.runningProfiles.length;
      yield DiagnosticCheck(
        'Профили',
        CheckStatus.ok,
        '${launcher.profiles.length} в списке, открыто $open',
      );
    }
  }

  Future<DiagnosticCheck> _events(ClaudeCodeIntegration code) async {
    const title = 'События Claude Code';
    if (!settings.claudeCodeEvents) {
      return const DiagnosticCheck(title, CheckStatus.info, 'Выключены');
    }
    if (code.error case final error?) {
      return DiagnosticCheck(
        title,
        CheckStatus.problem,
        error,
        fixLabel: 'Исправить',
        fix: code.repairHooks,
      );
    }
    final missing = await code.missingHooks();
    if (missing == null) {
      return DiagnosticCheck(
        title,
        CheckStatus.problem,
        'Приём событий не запущен',
        fixLabel: 'Исправить',
        fix: code.repairHooks,
      );
    }
    if (missing > 0) {
      return DiagnosticCheck(
        title,
        CheckStatus.problem,
        'Хуков нет в $missing ${_folders(missing)} Claude Code — сессии этих '
        'профилей не видны на карточках.',
        fixLabel: 'Исправить',
        fix: code.repairHooks,
      );
    }
    return const DiagnosticCheck(title, CheckStatus.ok, 'Хуки на месте');
  }

  static String _folders(int count) =>
      count % 10 == 1 && count % 100 != 11 ? 'папке' : 'папках';

  Future<DiagnosticCheck> _links(ClaudeLinkHandler handler) async {
    const title = 'Ссылки claude://';
    if (!settings.claudeLinks) {
      return const DiagnosticCheck(
        title,
        CheckStatus.info,
        'Открывает Claude: лаунчер их не принимает (Настройки → «Основные»)',
      );
    }
    if (handler.blocked) {
      return DiagnosticCheck(
        title,
        CheckStatus.problem,
        'В «Приложениях по умолчанию» для claude выбран не лаунчер — '
        'выберите ClaudeLauncher.',
        fixLabel: openDefaultApps == null ? null : 'Выбрать',
        fix: openDefaultApps,
      );
    }
    if (!await handler.owned()) {
      return DiagnosticCheck(
        title,
        CheckStatus.warning,
        'Роль обработчика сейчас у Claude — лаунчер вернёт её сам в течение '
        'минуты.',
        fixLabel: 'Исправить',
        fix: handler.reclaim,
      );
    }
    return const DiagnosticCheck(title, CheckStatus.ok, 'Открывает лаунчер');
  }

  /// Открытые профили, которые Claude запустил без нужной настройки в `…-3p`:
  /// она читается только при запуске, поэтому помогает лишь перезапуск.
  Future<List<Profile>> _runningWithout(
    Future<bool> Function(String dataDir) has,
  ) async => [
    for (final profile in launcher.runningProfiles)
      if (!await has(launcher.dataDirOf(profile))) profile,
  ];

  Future<DiagnosticCheck> _killSwitch() async {
    const title = 'Kill Switch';
    final port = killSwitch?.gate.port ?? settings.egressPort;
    final unpinned = await _runningWithout(
      (dir) => config.isPinned(dir, port: port),
    );
    if (unpinned.isNotEmpty) {
      return DiagnosticCheck(
        title,
        CheckStatus.warning,
        '${_names(unpinned)} ${unpinned.length == 1 ? 'открыт' : 'открыты'} '
        'мимо затвора — перезапустите из лаунчера.',
      );
    }
    return DiagnosticCheck(
      title,
      CheckStatus.ok,
      (killSwitch?.serving ?? false) ? 'Затвор работает' : 'Включён',
    );
  }

  Future<DiagnosticCheck> _updateHold() async {
    const title = 'Обновление Claude';
    final free = await _runningWithout(config.holdsUpdates);
    if (free.isNotEmpty) {
      return DiagnosticCheck(
        title,
        CheckStatus.warning,
        '${_names(free)} может обновить Claude сам — перезапустите '
        'из лаунчера.',
      );
    }
    return const DiagnosticCheck(
      title,
      CheckStatus.ok,
      'Claude не обновляется сам — обновляет лаунчер',
    );
  }

  DiagnosticCheck _cowork(CoworkFirewall firewall) {
    const title = 'Cowork и Kill Switch';
    if (firewall.active ?? false) {
      return const DiagnosticCheck(
        title,
        CheckStatus.ok,
        'Машина Cowork выходит в сеть только через затвор',
      );
    }
    return DiagnosticCheck(
      title,
      CheckStatus.info,
      'Машина Cowork может выходить в сеть мимо затвора',
      fixLabel: firewall.busy ? null : 'Включить правило',
      fix: firewall.busy ? null : firewall.enable,
    );
  }

  Future<DiagnosticCheck> _sessions() async {
    const title = 'Сессии Code';
    final profiles = await readSessions();
    final unreadable = profiles.fold<int>(0, (sum, p) => sum + p.unreadable);
    if (unreadable > 0) {
      return DiagnosticCheck(
        title,
        CheckStatus.warning,
        'Claude изменил формат: $unreadable ${_sessionsWord(unreadable)} '
        'лаунчер не понял — их нет на карточках и в переносе.',
      );
    }
    final unknown = [
      for (final p in profiles)
        if (!p.identity.resolved && p.profile.lastLaunchedAt != null) p.profile,
    ];
    if (unknown.isNotEmpty) {
      return DiagnosticCheck(
        title,
        CheckStatus.info,
        'Не определён аккаунт: ${_names(unknown)} — откройте профиль, Claude '
        'допишет данные о входе.',
      );
    }
    final count = profiles.fold<int>(0, (sum, p) => sum + p.sessions.length);
    return DiagnosticCheck(title, CheckStatus.ok, 'Видно сессий: $count');
  }

  static String _sessionsWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'сессию';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
      return 'сессии';
    }
    return 'сессий';
  }

  static String _names(List<Profile> profiles) {
    final names = [for (final p in profiles) '«${p.name}»'];
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} и ${names.last}';
  }

  /// Текст для «Скопировать отчёт».
  String report(List<DiagnosticCheck> checks, {required String version}) {
    final mark = {
      CheckStatus.ok: '✓',
      CheckStatus.info: '·',
      CheckStatus.warning: '!',
      CheckStatus.problem: '✗',
    };
    return [
      'ClaudeLauncher $version · Claude ${claudeVersion ?? '?'} · '
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Одновременная работа: ${settings.parallelLaunch ? 'да' : 'нет'}, '
          'Kill Switch: ${settings.killSwitch ? 'да' : 'нет'}',
      '',
      for (final check in checks)
        '${mark[check.status]} ${check.title} — ${check.detail}',
    ].join('\n');
  }
}
