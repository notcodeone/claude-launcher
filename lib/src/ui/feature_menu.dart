import 'package:flutter/material.dart';

import 'settings_pages.dart' show AppearIn, LerpHero;
import 'theme.dart';
import 'widgets.dart';

/// Функция на странице «Возможности».
class FeatureTile<T> {
  const FeatureTile({
    required this.value,
    required this.icon,
    required this.title,
    required this.text,
    this.soon = false,
  });

  final T value;
  final IconData icon;
  final String title;

  /// Что это — в одну строку (проверяет тест).
  final String text;

  /// Запланировано, но ещё не сделано: видно с пометкой «Скоро», не нажимается.
  final bool soon;
}

/// Группа на странице «Возможности»: подпись и карточка с функциями.
class FeatureSection<T> {
  const FeatureSection({required this.title, required this.tiles});

  final String title;
  final List<FeatureTile<T>> tiles;
}

/// Страница «Возможности»: то, что лаунчер умеет помимо переключения
/// профилей, — группами, как разделы «Настроек»: подпись группы на фоне окна
/// и карточка со строками ([NavRow]). Нажатие на функцию — [onOpen].
class FeaturesPage extends StatelessWidget {
  const FeaturesPage({
    super.key,
    required this.padding,
    required this.onOpen,
    this.sections = appFeatures,
  });

  final EdgeInsets padding;
  final ValueChanged<String> onOpen;
  final List<FeatureSection<String>> sections;

  @override
  Widget build(BuildContext context) {
    var index = 0;
    return ListView(
      padding: padding,
      children: [
        for (final (number, section) in sections.indexed) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(4, number == 0 ? 0 : 20, 4, 0),
            child: AppearIn(index: index, child: FieldLabel(section.title)),
          ),
          AppearIn(
            index: index++,
            child: SoftCard(
              padding: EdgeInsets.zero,
              // Подсветка строк — по скруглённым углам карточки.
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Column(
                  children: [
                    for (final (row, tile) in section.tiles.indexed) ...[
                      if (row > 0) const Divider(height: 1),
                      FeatureRow(
                        tile: tile,
                        onTap: tile.soon ? null : () => onOpen(tile.value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Строка функции — как строка «Настроек» ([NavRow]): значок, название,
/// описание в одну строку и стрелка — или «Скоро».
class FeatureRow<T> extends StatelessWidget {
  const FeatureRow({super.key, required this.tile, this.onTap});

  final FeatureTile<T> tile;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final color = tile.soon ? p.muted : p.text;
    return NavRow(
      onTap: onTap,
      // Запланированное никуда не ведёт — без Hero.
      leading: tile.soon
          ? Icon(tile.icon, size: NavRow.iconSize, color: color)
          : FeatureIcon(tile: tile),
      title: tile.soon
          ? Text(
              tile.title,
              style: theme.textTheme.titleMedium?.copyWith(color: color),
            )
          : FeatureTitle(tile: tile),
      subtitle: Text(
        tile.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: tile.soon
          ? const Tag(label: 'Скоро')
          : Icon(AppIcons.chevron, size: 18, color: p.muted),
    );
  }
}

/// Значок и название функции в заголовке её страницы — как у разделов
/// «Настроек»: из строки списка они перелетают сюда каждый своим Hero.
class FeatureHeading<T> extends StatelessWidget {
  const FeatureHeading({super.key, required this.tile});

  final FeatureTile<T> tile;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FeatureIcon(tile: tile, t: 1),
      const SizedBox(width: 12),
      Flexible(child: FeatureTitle(tile: tile, t: 1)),
    ],
  );
}

/// Значок функции: 0 — в строке списка, 1 — в заголовке страницы.
class FeatureIcon<T> extends StatelessWidget {
  const FeatureIcon({super.key, required this.tile, this.t = 0});

  final FeatureTile<T> tile;
  final double t;

  @override
  Widget build(BuildContext context) => LerpHero(
    tag: 'feature-icon-${tile.value}',
    t: t,
    builder: (t, color) =>
        Icon(tile.icon, size: NavRow.iconSize + 2 * t, color: color),
  );
}

/// Название функции: 0 — в строке списка, 1 — в заголовке страницы.
class FeatureTitle<T> extends StatelessWidget {
  const FeatureTitle({super.key, required this.tile, this.t = 0});

  final FeatureTile<T> tile;
  final double t;

  @override
  Widget build(BuildContext context) => LerpHero(
    tag: 'feature-title-${tile.value}',
    t: t,
    builder: (t, color) => Text(
      tile.title,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 15 + 7 * t,
        fontWeight: FontWeight.lerp(FontWeight.w600, FontWeight.w700, t),
        letterSpacing: -0.3 * t,
        color: color,
      ),
    ),
  );
}

/// Функция по [value] — для заголовка её страницы.
FeatureTile<String> featureTile(String value) => [
  for (final section in appFeatures) ...section.tiles,
].firstWhere((tile) => tile.value == value);

/// Что есть в «Возможностях». Описания — в одну строку и по смыслу: что
/// человек получит, а не как это устроено. Запланированное — по
/// docs/dev/roadmap.md.
const appFeatures = <FeatureSection<String>>[
  FeatureSection(
    title: 'Сессии',
    tiles: [
      FeatureTile(
        value: 'sessions',
        icon: AppIcons.sessions,
        title: 'Сессии',
        text: 'Где лежат сессии Code — по проектам и профилям',
      ),
      FeatureTile(
        value: 'sync',
        icon: AppIcons.sync,
        title: 'Синхронизация сессий',
        text: 'Сессии Code сами появляются в других профилях',
      ),
    ],
  ),
  FeatureSection(
    title: 'Claude',
    tiles: [
      FeatureTile(
        value: 'connectors',
        icon: AppIcons.connectors,
        title: 'MCP и расширения',
        text: 'Перенос подключений Claude между профилями',
        soon: true,
      ),
      FeatureTile(
        value: 'limits',
        icon: AppIcons.charts,
        title: 'Лимиты',
        text: 'Сколько осталось в каждом профиле прямо сейчас',
        soon: true,
      ),
    ],
  ),
];
