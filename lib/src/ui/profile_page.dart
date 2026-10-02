import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../launcher_controller.dart';
import '../profile.dart';
import 'profile_dialog.dart';
import 'profile_icons.dart';
import 'announcements.dart' show Snacks;
import 'settings_pages.dart' show AppearIn;
import 'snackbar.dart';
import 'theme.dart';
import 'widgets.dart';

/// Hero профиля: кнопка «Добавить» ↔ аватар нового профиля ↔ аватар его
/// карточки в списке.
///
/// Кнопка в полёте превращается в аватар: прямоугольник скругляется в круг,
/// чёрный цвет перетекает в цвет метки, «+ Добавить» гаснет, а значок профиля
/// проявляется. Между аватарами — просто перелёт с изменением размера.
class ProfileHero extends StatelessWidget {
  /// Аватар — на странице профиля или в карточке.
  const ProfileHero.avatar({
    super.key,
    required this.tag,
    required this.marker,
    required this.icon,
    required this.child,
  }) : fabIcon = null,
       fabLabel = null;

  /// Кнопка «Добавить» — превращается в аватар нового профиля.
  const ProfileHero.fab({
    super.key,
    required IconData this.fabIcon,
    required String this.fabLabel,
    required this.child,
  }) : tag = newProfileTag,
       marker = Profile.defaultMarker,
       icon = Profile.defaultIcon;

  /// Кнопка «Добавить» и аватар на странице нового профиля.
  static const newProfileTag = 'profile-new';

  /// Аватар карточки профиля [id].
  static String avatarTag(String id) => 'profile-avatar-$id';

  final Object tag;
  final String marker;
  final String icon;
  final IconData? fabIcon;
  final String? fabLabel;
  final Widget child;

  bool get _isFab => fabLabel != null;

  @override
  Widget build(BuildContext context) => Hero(
    tag: tag,
    // Дугой, как в Material: по прямой полёт снизу справа вверх влево
    // выглядел бы механически.
    createRectTween: (begin, end) =>
        MaterialRectArcTween(begin: begin, end: end),
    flightShuttleBuilder: _shuttle,
    child: child,
  );

  static Widget _shuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    ProfileHero? of(BuildContext context) =>
        context.findAncestorWidgetOfExactType<ProfileHero>();

    final from = of(fromHeroContext);
    final to = of(toHeroContext);
    final fab = [
      from,
      to,
    ].firstWhere((h) => h?._isFab ?? false, orElse: () => null);
    final avatar = [
      from,
      to,
    ].firstWhere((h) => h != null && !h._isFab, orElse: () => null);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        // Без кнопки (аватар → карточка) — просто аватар нужного размера.
        if (fab == null || avatar == null) {
          final hero = to ?? from;
          return hero == null
              ? const SizedBox.shrink()
              : LayoutBuilder(
                  builder: (context, size) => ProfileAvatar(
                    marker: hero.marker,
                    icon: hero.icon,
                    size: min(size.maxWidth, size.maxHeight),
                  ),
                );
        }
        // Push и pop идут по одной анимации маршрута: 0 — кнопка, 1 — аватар.
        return _Morph(
          t: curved.value,
          fabIcon: fab.fabIcon!,
          fabLabel: fab.fabLabel!,
          marker: avatar.marker,
          icon: avatar.icon,
        );
      },
    );
  }
}

/// Кадр превращения кнопки в аватар: [t] = 0 — кнопка, 1 — аватар.
class _Morph extends StatelessWidget {
  const _Morph({
    required this.t,
    required this.fabIcon,
    required this.fabLabel,
    required this.marker,
    required this.icon,
  });

  final double t;
  final IconData fabIcon;
  final String fabLabel;
  final String marker;
  final String icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = markerColor(marker);
    final iconColor = color.computeLuminance() > 0.5
        ? const Color(0xFF0A0A0A)
        : Colors.white;
    // Кнопка гаснет в первой половине, значок профиля проявляется во второй.
    final fabOpacity = (1 - t * 2).clamp(0.0, 1.0);
    final avatarOpacity = (t * 2 - 1).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, size) {
        final side = min(size.maxWidth, size.maxHeight);
        return Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: Color.lerp(p.primary, color, t),
              borderRadius: BorderRadius.circular(lerpDouble(16, side / 2, t)!),
              boxShadow: [
                for (final shadow in p.softShadow) shadow.scale(1 - t),
              ],
            ),
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: fabOpacity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 18, right: 22),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(fabIcon, color: p.onPrimary, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            fabLabel,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.onPrimary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Opacity(
                  opacity: avatarOpacity,
                  child: Icon(
                    profileIcon(icon),
                    size: side * 0.5,
                    color: iconColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Страница профиля внутри окна — новый ([profile] = null) или правка
/// существующего. Аватар вверху сразу показывает выбранные метку и иконку;
/// «Создать» / «Сохранить» — на месте кнопки «Добавить», назад — стрелкой в
/// шапке или Esc.
///
/// Hero: новому профилю аватар достаётся от кнопки «Добавить», при правке —
/// прилетает из карточки профиля и после сохранения возвращается в неё.
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.launcher,
    required this.padding,
    required this.onDone,
    this.profile,
    this.bottomScrim,
  });

  /// Затемнение над подвалом окна — между списком и кнопкой (Positioned).
  final Widget? bottomScrim;

  final LauncherController launcher;
  final EdgeInsets padding;

  /// Профиль для правки; null — новый.
  final Profile? profile;

  /// Вернуться к профилям — после создания или отмены.
  final VoidCallback onDone;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _email = TextEditingController(text: widget.profile?.email);
  late final _note = TextEditingController(text: widget.profile?.note);
  late String _marker = widget.profile?.marker ?? Profile.defaultMarker;
  late String _icon = widget.profile?.icon ?? Profile.defaultIcon;
  String? _nameError;
  bool _saving = false;

  bool get _isNew => widget.profile == null;

  /// Новый профиль, пока не создан, связан с кнопкой «Добавить», после — с
  /// его карточкой: туда аватар и улетит. Правка — всегда с карточкой.
  late Object _heroTag = switch (widget.profile) {
    final profile? => ProfileHero.avatarTag(profile.id),
    null => ProfileHero.newProfileTag,
  };

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _folderLabel {
    if (widget.profile case final profile?) {
      return 'Данные профиля: ${widget.launcher.dataDirOf(profile)}';
    }
    final name = _name.text.trim();
    final folder = folderNameFor(name.isEmpty ? 'profile' : name, [
      for (final profile in widget.launcher.profiles) ?profile.folderName,
    ]);
    return 'Данные профиля будут в '
        '${p.join(widget.launcher.host.profilesBaseDir, folder)}. '
        'При первом запуске войдите в аккаунт — дальше вход сохранится.';
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Введите название');
      return;
    }
    setState(() => _saving = true);
    final name = _name.text.trim();
    final email = _email.text.trim();
    final note = _note.text.trim();
    if (widget.profile case final profile?) {
      await widget.launcher.updateProfile(
        profile.copyWith(
          name: name,
          email: email,
          note: note,
          marker: _marker,
          icon: _icon,
        ),
      );
      if (!mounted) return;
      widget.onDone();
      AppSnackbar.show(Snacks.profileSaved(name));
      return;
    }
    final profile = await widget.launcher.addProfile(
      name: name,
      email: email,
      note: note,
      marker: _marker,
      icon: _icon,
    );
    if (!mounted) return;
    // Новый тег — до возврата: аватар улетит в карточку нового профиля.
    setState(() => _heroTag = ProfileHero.avatarTag(profile.id));
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone());
    final launcher = widget.launcher;
    AppSnackbar.show(
      Snacks.profileCreated(name, () => launcher.switchTo(profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            padding: widget.padding,
            children: [
              Row(
                children: [
                  ProfileHero.avatar(
                    tag: _heroTag,
                    marker: _marker,
                    icon: _icon,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: ProfileAvatar(
                        key: ValueKey('$_marker/$_icon'),
                        marker: _marker,
                        icon: _icon,
                        size: 56,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: AppearIn(
                      index: 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isNew ? 'Новый профиль' : 'Профиль',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Отдельный вход в Claude со своими сессиями.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              AppearIn(
                index: 1,
                child: SoftCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const FieldLabel('Название'),
                                AppTextField(
                                  controller: _name,
                                  autofocus: true,
                                  hintText: 'Например, Рабочий',
                                  errorText: _nameError,
                                  // Перерисовка — для пути папки и чтобы
                                  // убрать ошибку.
                                  onChanged: (_) =>
                                      setState(() => _nameError = null),
                                  onSubmitted: (_) => _submit(),
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
                                AppTextField(
                                  controller: _email,
                                  hintText: 'ivan@example.com',
                                  onSubmitted: (_) => _submit(),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const FieldLabel('Заметка'),
                      AppTextField(
                        controller: _note,
                        minLines: 1,
                        maxLines: 3,
                        hintText: 'Например, проекты компании',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AppearIn(
                index: 2,
                child: SoftCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FieldLabel('Метка'),
                      ChoiceGrid(
                        children: [
                          for (final marker in Profile.markers)
                            ChoiceCircle(
                              selected: marker == _marker,
                              ring: true,
                              onTap: () => setState(() => _marker = marker),
                              child: MarkerDot(marker: marker, size: 24),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const FieldLabel('Иконка'),
                      ChoiceGrid(
                        children: [
                          for (final MapEntry(key: key, value: icon)
                              in profileIcons.entries)
                            ChoiceCircle(
                              selected: key == _icon,
                              onTap: () => setState(() => _icon = key),
                              child: Icon(icon, size: 24, color: palette.text),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AppearIn(
                index: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(_folderLabel, style: theme.textTheme.bodySmall),
                ),
              ),
            ],
          ),
        ),
        ?widget.bottomScrim,
        // «Создать» / «Сохранить» — там же, где была «Добавить».
        Positioned(
          right: widget.padding.right,
          bottom: newProfileFabBottom,
          child: AppearIn(
            index: 3,
            child: FabSlot(
              child: AppFab(
                icon: AppIcons.check,
                label: switch ((_isNew, _saving)) {
                  (true, false) => 'Создать',
                  (true, true) => 'Создаю…',
                  (false, false) => 'Сохранить',
                  (false, true) => 'Сохраняю…',
                },
                onPressed: _submit,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Отступ кнопки «Добавить» / «Создать» от низа окна: над подвалом.
const newProfileFabBottom = 40.0 + 8;
