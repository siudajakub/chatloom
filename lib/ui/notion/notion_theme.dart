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
    // The dock's language everywhere (DESIGN.md "Glass" and "Radius"):
    // pills for controls, rounded blocks for content, larger radii and the
    // glass hairline for floating overlays. Nothing is square.
    const shape = NotionShapes.md;
    const pill = NotionShapes.pill;
    final borderSide = BorderSide(color: border);
    final hairline = BorderSide(color: tokens.glass.border);
    final overlayShape = NotionShapes.lg.copyWith(side: hairline);
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
      borderRadius: NotionRadius.fieldAll,
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
      // Wider than tall so text clears the pill ends.
      contentPadding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.md,
        vertical: NotionSpace.sm,
      ),
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
      shape: WidgetStatePropertyAll(overlayShape),
      // Items sit inset so their rounded highlight clears the menu corners.
      padding: const WidgetStatePropertyAll(
        EdgeInsets.all(NotionSpace.xxs + 2),
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
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: NotionShapes.xl.copyWith(side: hairline),
        clipBehavior: Clip.antiAlias,
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
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        modalBarrierColor: c.scrim,
        dragHandleColor: border,
        dragHandleSize: const Size(36, 4),
        shape: NotionShapes.sheet.copyWith(side: hairline),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: overlayShape,
        menuPadding: const EdgeInsets.symmetric(vertical: NotionSpace.xxs + 2),
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
          shape: NotionShapes.row,
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
        shape: NotionShapes.row,
        visualDensity: VisualDensity.standard,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: secondary,
        collapsedIconColor: secondary,
        textColor: text,
        collapsedTextColor: text,
        tilePadding: NotionSpace.page,
        shape: NotionShapes.row,
        collapsedShape: NotionShapes.row,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: NotionShapes.xs,
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
          // A circle at the square touch target, like the dock's icons.
          shape: pill,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: text,
        unselectedLabelColor: secondary,
        labelStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
        unselectedLabelStyle: t.callout,
        // A pill behind the selected tab instead of an underline; it slides
        // elastically between tabs.
        indicator: NotionPillTabIndicator(color: selected),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorAnimation: TabIndicatorAnimation.elastic,
        splashBorderRadius: NotionRadius.pillAll,
        dividerColor: Colors.transparent,
        dividerHeight: 0,
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .04)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: selected,
        indicatorShape: pill,
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
        indicatorShape: pill,
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
        indicatorShape: pill,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrimColor: c.scrim,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadiusDirectional.horizontal(
            end: Radius.circular(NotionRadius.xl),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.text,
          borderRadius: NotionRadius.lgAll,
        ),
        textStyle: t.caption.copyWith(color: background),
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.sm,
          vertical: NotionSpace.xxs + 1,
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
          shape: const WidgetStatePropertyAll(pill),
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
        shape: pill,
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
        shape: const WidgetStatePropertyAll(pill),
        side: WidgetStatePropertyAll(borderSide),
        textStyle: WidgetStatePropertyAll(t.callout),
        hintStyle: WidgetStatePropertyAll(
          t.callout.copyWith(color: c.textTertiary),
        ),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: NotionSpace.md),
        ),
      ),
      searchViewTheme: SearchViewThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        dividerColor: border,
        headerTextStyle: t.callout,
        headerHintStyle: t.callout.copyWith(color: c.textTertiary),
        shape: NotionShapes.xl,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: selected,
        disabledColor: surface.withValues(alpha: .5),
        labelStyle: t.footnote,
        showCheckmark: false,
        side: BorderSide.none,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xs),
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
          shape: pill,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surface,
          foregroundColor: text,
          elevation: 0,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          minimumSize: const Size(64, 40),
          shape: pill,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: borderSide,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          minimumSize: const Size(64, 40),
          shape: pill,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          textStyle: t.callout.copyWith(fontWeight: FontWeight.w500),
          shape: pill,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: text,
        linearTrackColor: border,
        circularTrackColor: Colors.transparent,
        borderRadius: NotionRadius.pillAll,
        strokeCap: StrokeCap.round,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: t.callout,
        actionTextColor: text,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        // A floating rounded block with the dock's hairline and inset.
        shape: overlayShape,
        insetPadding: const EdgeInsets.fromLTRB(
          NotionGlass.floatingInset,
          NotionSpace.xxs,
          NotionGlass.floatingInset,
          NotionSpace.sm,
        ),
      ),
    );
  }
}

/// The selected-tab pill: a rounded fill inset from the tab bounds, so tabs
/// read like the dock's segments instead of an underline.
class NotionPillTabIndicator extends Decoration {
  final Color color;
  final EdgeInsets inset;

  const NotionPillTabIndicator({
    required this.color,
    this.inset = const EdgeInsets.symmetric(
      horizontal: NotionSpace.xxs,
      vertical: NotionSpace.xxs + 2,
    ),
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _PillTabPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is NotionPillTabIndicator &&
      other.color == color &&
      other.inset == inset;

  @override
  int get hashCode => Object.hash(color, inset);
}

class _PillTabPainter extends BoxPainter {
  final NotionPillTabIndicator decoration;
  _PillTabPainter(this.decoration, super.onChanged);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = decoration.inset.deflateRect(offset & size);
    if (rect.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)),
      Paint()..color = decoration.color,
    );
  }
}
