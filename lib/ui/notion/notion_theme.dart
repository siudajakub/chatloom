// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../pages/chat/conversation_bubble.dart';
import 'notion_motion.dart';
import 'notion_tokens.dart';

/// Builds the only [ThemeData] of the app from [NotionColors].
///
/// Every Material component the app uses gets a Notion component theme here,
/// so plain Material widgets already look right. See `client/DESIGN.md`.
abstract final class NotionTheme {
  /// One page motion for every route: Notion slide+fade with predictive
  /// back on Android and desktop, native Cupertino on iOS.
  static const pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: NotionPageTransitionsBuilder(),
      TargetPlatform.fuchsia: NotionPageTransitionsBuilder(),
      TargetPlatform.linux: NotionPageTransitionsBuilder(),
      TargetPlatform.macOS: NotionPageTransitionsBuilder(),
      TargetPlatform.windows: NotionPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    },
  );

  static ThemeData build(Brightness brightness, [Color? seed]) {
    final dark = brightness == Brightness.dark;
    final base = dark ? NotionColors.dark : NotionColors.light;
    final accent = seed == null
        ? base.text
        : ColorScheme.fromSeed(seedColor: seed, brightness: brightness).primary;
    final c = base.copyWith(
      accent: accent,
      onAccent: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
          ? NotionColors.dark.text
          : NotionColors.light.text,
    );
    final tokens = NotionTokens(
      colors: c,
      glass: dark ? NotionGlass.dark : NotionGlass.light,
    );
    final t = tokens.typography;
    final background = c.background;
    final surface = c.surface;
    final selected = c.selected;
    final text = c.text;
    final secondary = c.textSecondary;
    final border = c.border;
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
          error: c.danger,
          onError: background,
          errorContainer: c.danger.withValues(alpha: .16),
          onErrorContainer: c.danger,
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
          scrim: c.scrim,
          shadow: c.scrim,
        );
    const shape = RoundedRectangleBorder(borderRadius: NotionRadius.mdAll);
    const smallShape = RoundedRectangleBorder(borderRadius: NotionRadius.smAll);
    final borderSide = BorderSide(color: border);
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
      borderRadius: NotionRadius.mdAll,
      borderSide: BorderSide(color: color),
    );
    final inputTheme = InputDecorationTheme(
      filled: false,
      isDense: true,
      hintStyle: t.calloutMuted.copyWith(color: c.textTertiary),
      labelStyle: t.calloutMuted,
      helperStyle: t.captionMuted,
      errorStyle: t.caption.copyWith(color: c.danger),
      prefixIconColor: secondary,
      suffixIconColor: secondary,
      contentPadding: const EdgeInsets.all(NotionSpace.sm),
      border: outline(border),
      enabledBorder: outline(border),
      disabledBorder: outline(border.withValues(alpha: .5)),
      focusedBorder: outline(secondary),
      errorBorder: outline(c.danger),
      focusedErrorBorder: outline(c.danger),
    );
    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(surface),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(2),
      shape: WidgetStatePropertyAll(shape.copyWith(side: borderSide)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: NotionSpace.xxs),
      ),
    );
    WidgetStateProperty<Color?> selectedFill(Color on, Color off) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? on : off,
        );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Roboto',
      brightness: brightness,
      colorScheme: scheme,
      extensions: [
        tokens,
        dark
            ? ConversationBubbleColors.dark
            : ConversationBubbleColors.light(scheme),
      ],
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: border,
      disabledColor: c.textTertiary,
      hintColor: c.textTertiary,
      visualDensity: VisualDensity.standard,
      hoverColor: text.withValues(alpha: .06),
      focusColor: accent.withValues(alpha: .14),
      splashColor: text.withValues(alpha: .05),
      highlightColor: text.withValues(alpha: .04),
      // InkSparkle needs a fragment shader on first touch; the plain ripple
      // is cheaper and matches the quiet Notion look.
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: pageTransitions,
      textTheme: TextTheme(
        displayLarge: t.title,
        displayMedium: t.title,
        displaySmall: t.title,
        headlineLarge: t.title,
        headlineMedium: t.title,
        headlineSmall: t.heading,
        titleLarge: t.heading,
        titleMedium: t.headline,
        titleSmall: t.bodyStrong,
        bodyLarge: t.body,
        bodyMedium: t.callout,
        bodySmall: t.captionMuted,
        labelLarge: t.callout.copyWith(fontWeight: FontWeight.w500),
        labelMedium: t.footnote.copyWith(fontWeight: FontWeight.w500),
        labelSmall: t.micro,
      ),
      appBarTheme: AppBarTheme(
        toolbarHeight: NotionSize.headerHeight,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: t.headline.copyWith(fontFamily: 'Roboto'),
        iconTheme: IconThemeData(color: text, size: NotionSize.iconMd),
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
      dividerTheme: DividerThemeData(
        color: border,
        thickness: NotionSize.border,
        space: NotionSize.border,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: shape,
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: shape.copyWith(side: borderSide),
        barrierColor: c.scrim,
        titleTextStyle: t.headline,
        contentTextStyle: t.callout,
        actionsPadding: const EdgeInsets.fromLTRB(
          NotionSpace.md,
          0,
          NotionSpace.md,
          NotionSpace.md,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: background,
        modalBackgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        modalBarrierColor: c.scrim,
        dragHandleColor: border,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(
          borderRadius: NotionRadius.sheetTop,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: shape.copyWith(side: borderSide),
        textStyle: t.callout,
        labelTextStyle: WidgetStatePropertyAll(t.callout),
        iconColor: secondary,
        iconSize: NotionSize.icon,
      ),
      menuTheme: MenuThemeData(style: menuStyle),
      menuBarTheme: MenuBarThemeData(style: menuStyle),
      menuButtonTheme: MenuButtonThemeData(
        style: MenuItemButton.styleFrom(
          foregroundColor: text,
          iconColor: secondary,
          textStyle: t.callout,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: t.callout,
        menuStyle: menuStyle,
      ),
      iconTheme: IconThemeData(color: text, size: NotionSize.iconMd),
      inputDecorationTheme: inputTheme,
      listTileTheme: ListTileThemeData(
        contentPadding: NotionSpace.page,
        minVerticalPadding: 10,
        minTileHeight: NotionSize.rowMinHeight,
        horizontalTitleGap: 14,
        minLeadingWidth: NotionSize.iconLg,
        iconColor: secondary,
        textColor: text,
        titleTextStyle: t.body,
        subtitleTextStyle: t.footnoteMuted,
        leadingAndTrailingTextStyle: t.footnoteMuted,
        selectedColor: text,
        selectedTileColor: selected,
        tileColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        visualDensity: VisualDensity.standard,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: secondary,
        collapsedIconColor: secondary,
        textColor: text,
        collapsedTextColor: text,
        tilePadding: NotionSpace.page,
        shape: const RoundedRectangleBorder(),
        collapsedShape: const RoundedRectangleBorder(),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(3)),
        ),
        side: BorderSide(color: secondary, width: 1.5),
        fillColor: selectedFill(text, Colors.transparent),
        checkColor: WidgetStatePropertyAll(background),
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .06)),
      ),
      radioTheme: RadioThemeData(
        fillColor: selectedFill(text, secondary),
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .06)),
      ),
      switchTheme: SwitchThemeData(
        trackColor: selectedFill(secondary.withValues(alpha: .4), surface),
        thumbColor: WidgetStatePropertyAll(text),
        trackOutlineColor: WidgetStatePropertyAll(border),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: text,
          disabledForegroundColor: c.textTertiary,
          iconSize: NotionSize.iconMd,
          minimumSize: const Size.square(NotionSize.touchTarget),
          shape: smallShape,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: text,
        unselectedLabelColor: secondary,
        labelStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
        unselectedLabelStyle: t.callout,
        indicatorColor: text,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorAnimation: TabIndicatorAnimation.elastic,
        dividerColor: border,
        dividerHeight: NotionSize.border,
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .04)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: selected,
        indicatorShape: shape,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => t.micro.copyWith(
            color: states.contains(WidgetState.selected) ? text : secondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: NotionSize.iconMd,
            color: states.contains(WidgetState.selected) ? text : secondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        elevation: 0,
        indicatorColor: selected,
        indicatorShape: shape,
        selectedIconTheme: IconThemeData(color: text, size: NotionSize.iconMd),
        unselectedIconTheme: IconThemeData(
          color: secondary,
          size: NotionSize.iconMd,
        ),
        selectedLabelTextStyle: t.micro.copyWith(color: text),
        unselectedLabelTextStyle: t.micro,
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: selected,
        indicatorShape: shape,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrimColor: c.scrim,
        shape: const RoundedRectangleBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.text,
          borderRadius: NotionRadius.smAll,
        ),
        textStyle: t.caption.copyWith(color: background),
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.xs,
          vertical: NotionSpace.xxs,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: text,
        textColor: background,
        textStyle: t.micro.copyWith(fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 5),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: selectedFill(selected, Colors.transparent),
          foregroundColor: selectedFill(text, secondary),
          side: WidgetStatePropertyAll(borderSide),
          shape: const WidgetStatePropertyAll(shape),
          textStyle: WidgetStatePropertyAll(t.callout),
          visualDensity: VisualDensity.standard,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: text,
        foregroundColor: background,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: shape,
        extendedTextStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: text,
        inactiveTrackColor: border,
        thumbColor: text,
        overlayColor: text.withValues(alpha: .12),
        valueIndicatorColor: text,
        valueIndicatorTextStyle: t.caption.copyWith(color: background),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(shape),
        side: WidgetStatePropertyAll(borderSide),
        textStyle: WidgetStatePropertyAll(t.callout),
        hintStyle: WidgetStatePropertyAll(
          t.callout.copyWith(color: c.textTertiary),
        ),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: NotionSpace.sm),
        ),
      ),
      searchViewTheme: SearchViewThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        dividerColor: border,
        headerTextStyle: t.callout,
        headerHintStyle: t.callout.copyWith(color: c.textTertiary),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: selected,
        disabledColor: surface.withValues(alpha: .5),
        labelStyle: t.footnote,
        showCheckmark: false,
        side: BorderSide.none,
        shape: smallShape,
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
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
          disabledBackgroundColor: selected,
          disabledForegroundColor: c.textTertiary,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          minimumSize: const Size(64, 40),
          shape: shape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surface,
          foregroundColor: text,
          elevation: 0,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          minimumSize: const Size(64, 40),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: borderSide,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          minimumSize: const Size(64, 40),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          shape: shape,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: text,
        linearTrackColor: border,
        circularTrackColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: t.callout,
        actionTextColor: text,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: shape.copyWith(side: borderSide),
      ),
    );
  }
}
