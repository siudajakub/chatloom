// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'notion.dart';

abstract final class NotionTheme {
  static ThemeData build(Brightness brightness, [Color? seed]) {
    final dark = brightness == Brightness.dark;
    final background = dark ? NotionTokens.background : const Color(0xFFFAF9F6);
    final surface = dark ? NotionTokens.surface : const Color(0xFFF0EFEB);
    final selected = dark ? NotionTokens.selected : const Color(0xFFE8E7E3);
    final text = dark ? NotionTokens.text : const Color(0xFF242424);
    final secondary = dark ? NotionTokens.secondary : const Color(0xFF65655F);
    final border = dark ? NotionTokens.border : const Color(0xFFD6D5D0);
    final accent = seed == null
        ? text
        : ColorScheme.fromSeed(seedColor: seed, brightness: brightness).primary;
    final scheme = ColorScheme.fromSeed(seedColor: text, brightness: brightness)
        .copyWith(
          primary: accent,
          onPrimary: background,
          primaryContainer: selected,
          onPrimaryContainer: text,
          secondary: text,
          onSecondary: background,
          secondaryContainer: surface,
          onSecondaryContainer: text,
          tertiary: secondary,
          onTertiary: background,
          tertiaryContainer: surface,
          onTertiaryContainer: text,
          surface: background,
          onSurface: text,
          onSurfaceVariant: secondary,
          surfaceContainerLowest: background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: selected,
          surfaceContainerHighest: selected,
          outline: border,
          outlineVariant: border,
          inverseSurface: text,
          onInverseSurface: background,
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NotionTokens.radius),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Roboto',
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: border,
      visualDensity: VisualDensity.standard,
      hoverColor: text.withValues(alpha: .06),
      focusColor: accent.withValues(alpha: .14),
      splashColor: text.withValues(alpha: .05),
      highlightColor: text.withValues(alpha: .04),
      textTheme: TextTheme(
        headlineLarge: NotionTokens.title.copyWith(color: text),
        headlineMedium: NotionTokens.title.copyWith(color: text),
        titleLarge: NotionTokens.heading.copyWith(color: text),
        titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        bodyLarge: NotionTokens.body.copyWith(color: text),
        bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: text),
        bodySmall: NotionTokens.caption.copyWith(color: secondary),
      ),
      appBarTheme: AppBarTheme(
        toolbarHeight: 56,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: brightness,
          systemNavigationBarColor: background,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: shape,
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      iconTheme: IconThemeData(color: text, size: 22),
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        hintStyle: TextStyle(color: secondary),
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: secondary),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: selected,
        showCheckmark: false,
        side: BorderSide.none,
        shape: shape,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? secondary.withValues(alpha: .4)
              : surface,
        ),
        thumbColor: WidgetStateProperty.all(text),
        trackOutlineColor: WidgetStateProperty.all(border),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: text,
        selectionColor: text.withValues(alpha: .22),
        selectionHandleColor: text,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: text,
          foregroundColor: background,
          shape: shape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surface,
          foregroundColor: text,
          elevation: 0,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: text),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: text),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
    );
  }
}
