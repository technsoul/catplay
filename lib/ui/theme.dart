import 'package:flutter/material.dart';

/// CAT design tokens, taken from the logo: deep navy ground, frosted-glass
/// surfaces, white text and the logo's blue as the one accent. Surfaces are
/// translucent so the ambient [AppBackdrop] glows through; dialogs and menus
/// use the opaque [sheet].
class AppColors {
  // Ground
  static const bg = Color(0xFF0B1120);
  static const shade = Color(0xFF080C16); // vignettes, scrims
  static const sheet = Color(0xFF141C2E); // dialogs, menus, tooltips
  static const sheetHigh = Color(0xFF1D2840);

  // Glass surfaces (white over the ground)
  static const surface = Color(0x0AFFFFFF); // side panels
  static const surfaceHigh = Color(0x0FFFFFFF); // cards, inputs, tiles
  static const raised = Color(0x29FFFFFF); // selected / focused
  static const glass = Color(0x0FFFFFFF); // chips & round buttons
  static const glassStrong = Color(0x29FFFFFF);
  static const glassBorder = Color(0x1AFFFFFF);
  static const glassBorderStrong = Color(0x57FFFFFF);
  static const border = Color(0x1AFFFFFF);

  // Text
  static const text = Color(0xFFF3F6FB);
  static const textSoft = Color(0xFFC4CDDD);
  static const textDim = Color(0xFF8E9AB0);

  // Accent (logo blue) & status
  static const accent = Color(0xFF1E7BF2);
  static const accentBright = Color(0xFF5AA2FF); // small accent text/icons on glass
  static const onAccent = Color(0xFFFFFFFF);
  static const live = Color(0xFFE5484D);
  static const success = Color(0xFF3DD68C);
  static const warning = Color(0xFFFF9A5C);
  static const star = Color(0xFFFFC24D); // ratings and favorites

  // Ambient backdrop
  static const glowBlue = Color(0xFF1E5FD6);
  static const glowIndigo = Color(0xFF3B3FA8);
  static const glowCyan = Color(0xFF167E9E);
}

class AppRadii {
  static const card = 18.0;
  static const tile = 14.0;
  static const input = 14.0;
  static const panel = 22.0;
  static const dialog = 22.0;
}

class AppSizes {
  /// Height of every inline control: search fields, pickers, pill buttons.
  static const control = 44.0;
}

/// Shared motion: everything eases out, lists stagger in.
class AppMotion {
  static const fast = Duration(milliseconds: 160);
  static const base = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 450);
  static const stagger = Duration(milliseconds: 60);
  static const curve = Curves.easeOutCubic;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.text,
    onSecondary: AppColors.bg,
    secondaryContainer: AppColors.glassStrong,
    onSecondaryContainer: AppColors.text,
    surface: AppColors.bg,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textDim,
    surfaceContainerLowest: AppColors.bg,
    surfaceContainerLow: AppColors.sheet,
    surfaceContainer: AppColors.sheet,
    surfaceContainerHigh: AppColors.sheet,
    surfaceContainerHighest: AppColors.sheetHigh,
    outline: AppColors.border,
    outlineVariant: AppColors.border,
    error: AppColors.live,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.sheet,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Segoe UI',
  );
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadii.input),
    borderSide: const BorderSide(color: AppColors.glassBorder),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: AppColors.surfaceHigh,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      selectedColor: AppColors.text,
      selectedTileColor: AppColors.raised,
      iconColor: AppColors.textDim,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.tile)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.glass,
      isDense: true,
      hintStyle: const TextStyle(color: AppColors.textDim),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.textSoft, width: 1.2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        shape: pill,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.glassBorder),
        backgroundColor: AppColors.glass,
        shape: pill,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.text, shape: pill),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.text),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.glass,
      selectedColor: AppColors.text,
      side: const BorderSide(color: AppColors.glassBorder),
      shape: pill,
      labelStyle: const TextStyle(color: AppColors.textSoft),
      secondaryLabelStyle: const TextStyle(color: AppColors.bg, fontWeight: FontWeight.w600),
      checkmarkColor: AppColors.bg,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.glass,
        selectedBackgroundColor: AppColors.text,
        selectedForegroundColor: AppColors.bg,
        foregroundColor: AppColors.textSoft,
        side: const BorderSide(color: AppColors.glassBorder),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.onAccent : AppColors.textDim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.accent : AppColors.surfaceHigh),
      trackOutlineColor: WidgetStateProperty.all(AppColors.glassBorder),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.text,
      thumbColor: AppColors.text,
      inactiveTrackColor: Color(0x33FFFFFF),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.tile),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(AppColors.sheet),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.tile),
          side: const BorderSide(color: AppColors.glassBorder),
        )),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: AppColors.sheetHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.glassBorder),
      ),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: WidgetStateProperty.all(false),
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(const Color(0x33FFFFFF)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.sheetHigh,
      contentTextStyle: const TextStyle(color: AppColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.tile)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.sheet,
      barrierColor: const Color(0xB3080C16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.dialog),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(AppColors.sheet)),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: Color(0x33FFFFFF),
    ),
  );
}
