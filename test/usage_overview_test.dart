import 'package:claude_launcher/src/integrations/profile_identity.dart';
import 'package:claude_launcher/src/integrations/profile_usage.dart';
import 'package:claude_launcher/src/integrations/usage_overview.dart';
import 'package:claude_launcher/src/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const work = Profile(id: 'w', name: 'Рабочий');
  const tester = Profile(id: 't', name: 'Тест');
  const own = Profile(id: 'o', name: 'Личный');
  const fresh = Profile(id: 'n', name: 'Новый');

  ProfileUsage usage(double session, double weekly) => ProfileUsage(
    limits: [
      UsageLimit(
        label: '5 часов',
        usedPercent: session,
        window: UsageWindow.session,
      ),
      UsageLimit(
        label: 'Неделя',
        usedPercent: weekly,
        window: UsageWindow.weekly,
      ),
    ],
  );

  test('профили одного аккаунта — одной группой', () {
    final groups = UsageOverview.groups(
      [work, tester, own, fresh],
      {
        'w': const ProfileIdentity(accountUuid: 'a', orgUuid: 'x'),
        't': const ProfileIdentity(accountUuid: 'a', orgUuid: 'x'),
        'o': const ProfileIdentity(accountUuid: 'b', orgUuid: 'y'),
      },
    );
    expect(groups, [
      [work, tester],
      [own],
      [fresh],
    ]);
  });

  group('подсказка о запасе', () {
    final busy = AccountUsage(profiles: [work], usage: usage(95, 40));
    final free = AccountUsage(profiles: [own], usage: usage(10, 30));
    final half = AccountUsage(profiles: [tester], usage: usage(20, 60));

    test('открытый почти исчерпан, у другого запас', () {
      expect(
        UsageOverview.spareHint([busy, half, free], (p) => p == work),
        'У «Личный» есть запас: 5 часов — 10%, неделя — 30%',
      );
    });

    test('исчерпан, но не открыт — молчим', () {
      expect(UsageOverview.spareHint([busy, free], (_) => false), isNull);
    });

    test('запаса нигде нет — молчим', () {
      expect(UsageOverview.spareHint([busy, half], (p) => p == work), isNull);
    });

    test('без данных запасом не считается', () {
      const unknown = AccountUsage(profiles: [fresh]);
      expect(
        UsageOverview.spareHint([busy, unknown], (p) => p == work),
        isNull,
      );
    });
  });
}
