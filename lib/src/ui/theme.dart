import 'package:flutter/material.dart';

/// Монохромная палитра в духе sensomni / NotNotes: белый фон, чёрные акценты,
/// серые подписи, мягкие тени вместо рамок. Тёмная тема — инверсия.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.background,
    required this.card,
    required this.field,
    required this.text,
    required this.muted,
    required this.primary,
    required this.onPrimary,
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.dangerSurface,
    required this.divider,
    required this.shadow,
    required this.cardBorder,
    required this.scrim,
  });

  final Color background;
  final Color card;

  /// Заливка полей ввода и спокойных плашек.
  final Color field;
  final Color text;
  final Color muted;
  final Color primary;
  final Color onPrimary;
  final Color success;

  /// «Ожидает»: Claude просит разрешение.
  final Color warning;

  /// «Ожидает»: Claude ждёт ответа.
  final Color info;
  final Color danger;
  final Color dangerSurface;
  final Color divider;
  final Color shadow;

  /// В светлой теме карточки держатся на тени; в тёмной тень не видна — нужна рамка.
  final Color cardBorder;

  /// Затемнение экрана под открытым меню.
  final Color scrim;

  static const light = Palette(
    background: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    field: Color(0xFFF3F3F4),
    text: Color(0xFF0A0A0A),
    muted: Color(0xFF6E7179),
    primary: Color(0xFF0A0A0A),
    onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF12A150),
    warning: Color(0xFFD97706),
    info: Color(0xFF2563EB),
    danger: Color(0xFFD93025),
    dangerSurface: Color(0xFFFDECEA),
    divider: Color(0xFFEAEAEC),
    shadow: Color(0x17000000),
    cardBorder: Color(0x00000000),
    scrim: Color(0x40000000),
  );

  static const dark = Palette(
    background: Color(0xFF0C0C0E),
    card: Color(0xFF17171A),
    field: Color(0xFF232327),
    text: Color(0xFFF4F4F5),
    muted: Color(0xFF9A9CA3),
    primary: Color(0xFFF4F4F5),
    onPrimary: Color(0xFF0A0A0A),
    success: Color(0xFF34C77B),
    warning: Color(0xFFF59E0B),
    info: Color(0xFF60A5FA),
    danger: Color(0xFFFF6B5E),
    dangerSurface: Color(0xFF3A1714),
    divider: Color(0xFF2A2A2F),
    shadow: Color(0x66000000),
    cardBorder: Color(0xFF27272C),
    scrim: Color(0x99000000),
  );

  List<BoxShadow> get softShadow => [
    BoxShadow(color: shadow, blurRadius: 28, offset: const Offset(0, 8)),
    BoxShadow(
      color: shadow.withValues(alpha: shadow.a * 0.6),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension PaletteContext on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}

/// Цвет кружка для метки профиля (в трее остаются эмодзи того же цвета).
Color markerColor(String marker) => switch (marker) {
  '🟢' => const Color(0xFF1FB45A),
  '🔵' => const Color(0xFF0B5CFF),
  '🟣' => const Color(0xFF7C4DFF),
  '🔴' => const Color(0xFFE53935),
  '🟠' => const Color(0xFFFF7A1A),
  '🟡' => const Color(0xFFFFC21A),
  '🟤' => const Color(0xFF8D5B3C),
  '⚫' => const Color(0xFF111111),
  '⚪' => const Color(0xFFFFFFFF),
  _ => const Color(0xFF9A9CA3),
};

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: p.onPrimary,
    secondary: p.primary,
    onSecondary: p.onPrimary,
    error: p.danger,
    onError: Colors.white,
    surface: p.background,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    outline: p.divider,
    outlineVariant: p.divider,
    surfaceContainerHighest: p.field,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);
  final radius12 = BorderRadius.circular(12);

  return base.copyWith(
    scaffoldBackgroundColor: p.background,
    extensions: [p],
    splashFactory: InkRipple.splashFactory,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.1,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.35),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 12.5,
        height: 1.35,
        color: p.muted,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.6,
        color: p.muted,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.danger, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.danger, width: 1.5),
      ),
      errorStyle: TextStyle(color: p.danger),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      menuPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: p.cardBorder),
      ),
      textStyle: TextStyle(color: p.text, fontSize: 14),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: p.cardBorder),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.primary,
      linearTrackColor: p.divider,
      linearMinHeight: 3,
    ),
    dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.primary,
      selectionColor: p.primary.withValues(alpha: 0.18),
    ),
    // Переключатель: чёрный, когда включён (в тёмной теме — белый); бегунок
    // одного размера в обоих положениях, без обводки дорожки.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.onPrimary
            : brightness == Brightness.light
            ? Colors.white
            : p.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.primary
            : brightness == Brightness.light
            ? const Color(0xFFD9D9DC)
            : const Color(0xFF3A3A40),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: p.onPrimary, fontSize: 12),
    ),
  );
}
