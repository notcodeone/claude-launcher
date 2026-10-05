import '../launcher_controller.dart';
import '../profile.dart';
import 'live_usage.dart';
import 'profile_identity.dart';
import 'profile_usage.dart';

/// Лимиты одного аккаунта: у профилей с общим аккаунтом они общие.
class AccountUsage {
  const AccountUsage({required this.profiles, this.email, this.usage});

  final List<Profile> profiles;
  final String? email;

  /// `null` — Claude ещё не сохранял лимиты (профиль не открывали после входа).
  final ProfileUsage? usage;

  UsageLimit? limit(UsageWindow window) =>
      usage?.limits.where((l) => l.window == window).firstOrNull;

  /// Самый израсходованный из пятичасового и недельного лимитов.
  double get worst => [
    for (final window in [UsageWindow.session, UsageWindow.weekly])
      limit(window)?.usedPercent ?? 0,
  ].fold(0, (a, b) => a > b ? a : b);
}

/// «Лимиты» в «Возможностях»: все аккаунты профилей и подсказка, где есть
/// запас. Лаунчер ничего не переключает сам (журнал решений) — только
/// подсказывает.
abstract final class UsageOverview {
  /// Почти исчерпан — от стольких процентов.
  static const nearlyOut = 90.0;

  /// Есть запас — оба лимита ниже стольких процентов.
  static const spare = 50.0;

  /// Профили по аккаунтам; без известного аккаунта — каждый отдельно.
  static List<List<Profile>> groups(
    List<Profile> profiles,
    Map<String, ProfileIdentity> identities,
  ) {
    final byAccount = <String, List<Profile>>{};
    final single = <List<Profile>>[];
    for (final profile in profiles) {
      final account = identities[profile.id]?.accountUuid;
      if (account == null) {
        single.add([profile]);
      } else {
        byAccount.putIfAbsent(account, () => []).add(profile);
      }
    }
    return [...byAccount.values, ...single];
  }

  /// [live] и [online] — спросить Anthropic (при открытии страницы); без
  /// [online] — последний ответ, иначе файлы Claude.
  static Future<List<AccountUsage>> read(
    LauncherController launcher, {
    ProfileUsageReader reader = const ProfileUsageReader(),
    LiveUsage? live,
    bool online = false,
  }) async => [
    for (final group in groups(launcher.profiles, launcher.identities))
      AccountUsage(
        profiles: group,
        email: launcher.identities[group.first.id]?.email,
        usage:
            await _live(group, live, online) ??
            await _read(reader, [
              for (final profile in group)
                ...launcher.readableDataDirsOf(profile),
            ]),
      ),
  ];

  /// Лимиты общие у всего аккаунта — хватит входа любого профиля группы.
  static Future<ProfileUsage?> _live(
    List<Profile> group,
    LiveUsage? live,
    bool online,
  ) async {
    if (live == null) return null;
    for (final profile in group) {
      final usage = online ? await live.fetch(profile) : live.cached(profile);
      if (usage != null) return usage;
    }
    return null;
  }

  static Future<ProfileUsage?> _read(
    ProfileUsageReader reader,
    List<String> dirs,
  ) async {
    try {
      return await reader.read(dirs);
    } catch (_) {
      return null; // Файлы Claude в непонятном виде — как «нет данных».
    }
  }

  /// Подсказка: у открытого аккаунта лимит почти исчерпан, а у другого —
  /// запас. `null` — подсказывать нечего.
  static String? spareHint(
    List<AccountUsage> accounts,
    bool Function(Profile) isRunning,
  ) {
    final busy = accounts.where(
      (a) => a.profiles.any(isRunning) && a.worst >= nearlyOut,
    );
    if (busy.isEmpty) return null;
    final free =
        accounts
            .where(
              (a) => !busy.contains(a) && a.usage != null && a.worst < spare,
            )
            .toList()
          ..sort((a, b) => a.worst.compareTo(b.worst));
    if (free.isEmpty) return null;
    final best = free.first;
    final session = best.limit(UsageWindow.session)?.usedPercent.round() ?? 0;
    final weekly = best.limit(UsageWindow.weekly)?.usedPercent.round() ?? 0;
    return 'У «${best.profiles.first.name}» есть запас: '
        '5 часов — $session%, неделя — $weekly%';
  }
}
