import 'package:flutter/material.dart';

/// The app's look, shared by the home page and the map: deep greens with a
/// lime accent, white rounded panels on soft shadows.
abstract final class AppStyle {
  static const bg = Color(0xFFF2F5F3);
  static const ink = Color(0xFF14201A);
  static const muted = Color(0xFF6B7A73);
  static const line = Color(0xFFE1E8E4);
  static const green = Color(0xFF167A4A);
  static const greenLight = Color(0xFF23955D);
  static const deep = Color(0xFF0D4A2E);
  static const lime = Color(0xFFC6F36B);
  static const danger = Color(0xFFD63B34);
  static const amber = Color(0xFFE08C1A);

  /// The big green surfaces (the home page's status card).
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [greenLight, deep],
  );

  /// Main action buttons, by what they do.
  static const goGradient = LinearGradient(colors: [Color(0xFF1E8C55), green]);
  static const stopGradient = LinearGradient(
    colors: [Color(0xFFE5524A), Color(0xFFB3261E)],
  );
  static const warnGradient = LinearGradient(
    colors: [Color(0xFFF0A23A), Color(0xFFD9741A)],
  );
  static const offGradient = LinearGradient(
    colors: [Color(0xFFA3AEA8), Color(0xFF86928C)],
  );

  /// Under white panels on the page.
  static const panelShadow = [
    BoxShadow(color: Color(0x0F0D3B24), blurRadius: 16, offset: Offset(0, 6)),
  ];

  /// Under things floating over the map, which may be bright or busy.
  static const floatShadow = [
    BoxShadow(color: Color(0x330D3B24), blurRadius: 18, offset: Offset(0, 6)),
  ];

  /// Under a green or red action button: a glow of its own colour.
  static List<BoxShadow> glow(Color color) => [
    BoxShadow(
      color: color.withValues(alpha: 0.4),
      blurRadius: 18,
      offset: const Offset(0, 8),
    ),
  ];

  /// The app's theme in this style: rounded buttons and fields, plain title
  /// bars on the page colour.
  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: green,
      brightness: Brightness.light,
    ).copyWith(primary: green);
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    // Built on the default text styles (a style given to a button or a bar
    // replaces the default one, font family and all).
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    final label = base.textTheme.labelLarge!.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: base.textTheme.titleLarge!.copyWith(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: rounded,
          minimumSize: const Size(64, 48),
          textStyle: label,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: rounded,
          minimumSize: const Size(64, 48),
          foregroundColor: ink,
          side: const BorderSide(color: line, width: 1.2),
          textStyle: label,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: green,
          textStyle: label,
          shape: rounded,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: green, width: 1.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.white : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? green : null,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.transparent : null,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1),
    );
  }
}

/// An icon on a tinted rounded tile, for list rows and card titles.
class AppIconTile extends StatelessWidget {
  const AppIconTile(this.icon, {super.key, this.color = AppStyle.green});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        dimension: 38,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

/// A group's title above its card on a settings-like page.
class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        text,
        style: const TextStyle(
          color: AppStyle.muted,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
