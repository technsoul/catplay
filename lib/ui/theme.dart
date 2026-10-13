import 'package:flutter/material.dart';

/// "Style B" palette: soft graphite surfaces, light text, one warm accent.
class AppColors {
  static const bg = Color(0xFF23242B);
  static const surface = Color(0xFF2A2B33); // side panels
  static const surfaceHigh = Color(0xFF33343D); // cards, inputs
  static const raised = Color(0xFF4A4B56); // selected / focused card
  static const border = Color(0xFF383943);
  static const glass = Color(0x0FFFFFFF); // translucent chips & round buttons
  static const glassBorder = Color(0x14FFFFFF);
  static const text = Color(0xFFEDEDF0);
  static const textDim = Color(0xFF9C9DA8);
  static const textSoft = Color(0xFFC8C9D2);
  static const accent = Color(0xFFFF7A2F);
  static const onAccent = Color(0xFF1B1C21);
  static const live = Color(0xFFE5484D);
  static const success = Color(0xFF3DD68C);
  static const warning = Color(0xFFFF9A5C);
}

class AppRadii {
  static const card = 18.0;
  static const tile = 14.0;
  static const input = 14.0;
  static const dialog = 22.0;
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
    secondaryContainer: AppColors.raised,
    onSecondaryContainer: AppColors.text,
    surface: AppColors.bg,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textDim,
    surfaceContainerLowest: AppColors.bg,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surfaceHigh,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.raised,
    outline: AppColors.border,
    outlineVariant: AppColors.border,
    error: AppColors.live,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
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
        backgroundColor: AppColors.text,
        foregroundColor: AppColors.bg,
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
      backgroundColor: AppColors.surfaceHigh,
      selectedColor: AppColors.text,
      side: BorderSide.none,
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
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.text,
      linearTrackColor: Color(0x33FFFFFF),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.text,
      thumbColor: AppColors.text,
      inactiveTrackColor: Color(0x33FFFFFF),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.tile)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(AppColors.surfaceHigh),
        shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.tile))),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(8),
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
      backgroundColor: AppColors.raised,
      contentTextStyle: const TextStyle(color: AppColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.tile)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.dialog)),
    ),
  );
}
