import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Visual language: deep ink neutrals with the Commit brand blue, a serif for
/// anything that reads like a record (titles, names, numbers, quotes) and a
/// clean grotesk for the interface. Each mode has its own accent, and the
/// whole app re-tints when it changes, so you always know which identity
/// you're calling from. Work mode wears the brand blue (from the logo).
class ModePalette {
  const ModePalette({
    required this.name,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.gradient,
    required this.glow,
    required this.icon,
  });

  final String name;
  final Color accent;
  final Color accentSoft;

  /// Text and icons drawn on top of [accent].
  final Color onAccent;
  final List<Color> gradient;

  /// Ambient light behind the home screen.
  final Color glow;
  final IconData icon;

  /// Sea-glass: calm and private.
  static const personal = ModePalette(
    name: 'Personal',
    accent: Color(0xFF6FD3BC),
    accentSoft: Color(0x1F6FD3BC),
    onAccent: Color(0xFF07211B),
    gradient: [Color(0xFF3FA892), Color(0xFF8EE3CF)],
    glow: Color(0xFF2E8C79),
    icon: Icons.spa_rounded,
  );

  /// Commit blue (the logo's #0046DC → #001352, lifted for contrast on dark): on duty, on the record.
  static const corporate = ModePalette(
    name: 'Work',
    accent: Color(0xFF3D7BFF),
    accentSoft: Color(0x263D7BFF),
    onAccent: Color(0xFFFFFFFF),
    gradient: [Color(0xFF0046DC), Color(0xFF4A86FF)],
    glow: Color(0xFF0046DC),
    icon: Icons.work_rounded,
  );

  /// The brand itself, used before sign-in and during onboarding.
  static const brand = corporate;
}

class AppColors {
  static const bg = Color(0xFF0B0D12);
  static const surface = Color(0xFF13161D);
  static const surfaceHigh = Color(0xFF1B1F28);
  static const outline = Color(0xFF272C38);
  static const hairline = Color(0x14E5ECFF);
  static const text = Color(0xFFF1F4F9);
  static const textDim = Color(0xFFA2A9B8);
  static const textFaint = Color(0xFF687083);
  static const success = Color(0xFF7FD48B);
  static const warning = Color(0xFFF2B544);
  static const danger = Color(0xFFF26B5B);
  static const info = Color(0xFF8FB8F2);
  static const recording = Color(0xFFFF5A4E);
}

/// Type helpers for places that style text directly.
class AppType {
  /// The serif: titles, names, big numbers, quotes.
  static TextStyle display(double size, {FontWeight weight = FontWeight.w600, Color color = AppColors.text, double? height, FontStyle? style}) =>
      GoogleFonts.fraunces(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height ?? 1.08,
        letterSpacing: size >= 24 ? -0.02 * size : -0.2,
        fontStyle: style,
      );

  /// Tabular figures for times, durations and the keypad.
  static TextStyle mono(double size, {FontWeight weight = FontWeight.w500, Color color = AppColors.text, double letterSpacing = 0}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color, letterSpacing: letterSpacing);
}

ThemeData buildTheme(ModePalette p) {
  final scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: Brightness.dark).copyWith(
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    outline: AppColors.outline,
    error: AppColors.danger,
  );
  const radius = BorderRadius.all(Radius.circular(18));
  final ui = GoogleFonts.manropeTextTheme(const TextTheme(
    displaySmall: TextStyle(fontSize: 38, fontWeight: FontWeight.w600, color: AppColors.text),
    headlineSmall: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: AppColors.text),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.text),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text, letterSpacing: -0.1),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.text),
    bodyLarge: TextStyle(fontSize: 16, color: AppColors.text, height: 1.45),
    bodyMedium: TextStyle(fontSize: 14, color: AppColors.textDim, height: 1.45),
    bodySmall: TextStyle(fontSize: 12, color: AppColors.textFaint),
    labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: AppColors.textFaint),
  ));
  // Headings use the serif.
  final text = ui.copyWith(
    displaySmall: AppType.display(38),
    headlineSmall: AppType.display(26),
    titleLarge: AppType.display(22),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.display(22),
      iconTheme: const IconThemeData(color: AppColors.text),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: AppColors.outline, width: .8)),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.outline, thickness: .8, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: AppColors.textDim,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodyMedium,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: const OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: AppColors.outline, width: .8)),
      enabledBorder: const OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: AppColors.outline, width: .8)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.accent, width: 1.4)),
      labelStyle: const TextStyle(color: AppColors.textDim),
      floatingLabelStyle: TextStyle(color: p.accent, fontWeight: FontWeight.w700),
      hintStyle: const TextStyle(color: AppColors.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: AppColors.surfaceHigh,
        minimumSize: const Size.fromHeight(54),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: .1),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: AppColors.outline),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.outline,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: GoogleFonts.manrope(color: AppColors.text, fontWeight: FontWeight.w600),
      shape: const StadiumBorder(side: BorderSide(color: AppColors.outline)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceHigh,
      selectedColor: p.accentSoft,
      side: const BorderSide(color: AppColors.outline, width: .8),
      shape: const StadiumBorder(),
      labelStyle: GoogleFonts.manrope(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w600),
      checkmarkColor: p.accent,
    ),
    // Kept for any screen still using the stock bar; the home shell has its own floating dock.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentSoft,
    ),
  );
}
