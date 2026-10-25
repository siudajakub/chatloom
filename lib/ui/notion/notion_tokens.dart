// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_appearance.dart';

/// Spacing scale. The only padding/gap values UI code should use.
///
/// Theme independent, so every value is `const` and usable in `const
/// EdgeInsets`. See `client/DESIGN.md`.
abstract final class NotionSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter used by every Notion screen.
  static const double inset = lg;

  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: inset);
  static const EdgeInsets row = EdgeInsets.symmetric(vertical: 10);
  static const EdgeInsets dialog = EdgeInsets.fromLTRB(xl, xl, xl, md);
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(lg, xs, lg, xl);
}

/// Corner radius scale: the rounded language of the floating dock.
///
/// Nothing in the app is square: the smallest radius is [xs]. Prefer the
/// bounded radii ([lg], [xl], [field]) over [pill] for anything that may grow
/// taller than one line; a radius larger than half the height is drawn as a
/// pill anyway, so a one-line control still reads as a capsule.
abstract final class NotionRadius {
  /// Checkboxes, inline code, thin tracks. The minimum radius in the app.
  static const double xs = 6;

  /// Small thumbnails, tags, quote thumbnails, inline media.
  static const double sm = 10;

  /// Cards, callouts, multi-line inputs, list selection highlights, media.
  static const double md = 16;

  /// Menus, popovers, snackbars, tooltips, large media.
  static const double lg = 20;

  /// Dialogs and the top corners of bottom sheets.
  static const double xl = 28;

  /// Badges, toggles, buttons, chips, the dock and fully rounded indicators.
  static const double pill = 999;

  /// Avatars are circles.
  static const double avatar = pill;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
  static const BorderRadius avatarAll = pillAll;

  /// Selected/pressed row highlight (inbox rows, settings categories, menu
  /// items): a rounded block, never a full-bleed rectangle.
  static const BorderRadius rowAll = mdAll;

  /// Composer field: a pill at one line that keeps soft corners (instead of
  /// round ends) when the editor grows to several lines. Also every text
  /// input (theme `InputDecoration`).
  static const double field = 26;
  static const BorderRadius fieldAll = BorderRadius.all(Radius.circular(field));
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

/// The shapes that go with [NotionRadius]; use them for `shape:` arguments
/// instead of a bare `RoundedRectangleBorder()` (which is square).
abstract final class NotionShapes {
  /// Buttons, chips, icon buttons (a circle when square), segmented buttons.
  static const OutlinedBorder pill = StadiumBorder();
  static const OutlinedBorder xs = RoundedRectangleBorder(
    borderRadius: NotionRadius.xsAll,
  );
  static const OutlinedBorder sm = RoundedRectangleBorder(
    borderRadius: NotionRadius.smAll,
  );
  static const OutlinedBorder md = RoundedRectangleBorder(
    borderRadius: NotionRadius.mdAll,
  );
  static const OutlinedBorder lg = RoundedRectangleBorder(
    borderRadius: NotionRadius.lgAll,
  );
  static const OutlinedBorder xl = RoundedRectangleBorder(
    borderRadius: NotionRadius.xlAll,
  );
  static const OutlinedBorder row = RoundedRectangleBorder(
    borderRadius: NotionRadius.rowAll,
  );
  static const OutlinedBorder sheet = RoundedRectangleBorder(
    borderRadius: NotionRadius.sheetTop,
  );
}

/// Fixed component and icon dimensions.
abstract final class NotionSize {
  static const double touchTarget = 48;
  static const double headerHeight = 56;
  static const double rowMinHeight = 52;
  static const double iconSm = 16;
  static const double icon = 20;
  static const double iconMd = 22;
  static const double iconLg = 24;
  static const double avatarSm = 24;
  static const double avatar = 40;
  static const double avatarLg = 56;
  static const double border = 1;
  static const double dialogMaxWidth = 420;
  static const double contentMaxWidth = 720;

  /// [showNotionSheet] becomes a centred dialog on desktop from this window
  /// width (MAC-18), up to the max size below.
  static const double sheetDialogMinWidth = 720;
  static const double sheetDialogMaxWidth = 480;
  static const double sheetDialogMaxHeight = 720;
}

/// Message bubble geometry (Messenger-like). A one-line bubble is about
/// `2 * outer` tall, so it reads as a pill; taller ones keep soft corners.
abstract final class NotionBubble {
  /// Free corners, and the top corners of a reply.
  static const double outer = 18;

  /// Sender-side corners where a bubble joins its neighbour in a group.
  static const double joined = 4;

  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: sm,
    vertical: xs,
  );

  /// Between bubbles of one group, and between groups.
  static const double groupGap = 2;
  static const double seriesGap = 14;

  /// Gap between a round video and the bubble above it.
  static const double roundGap = xs;

  /// How far a reply bubble covers the bottom of the quoted message.
  static const double quoteOverlap = 12;
  static const EdgeInsets quotePadding = EdgeInsets.fromLTRB(
    sm,
    7,
    sm,
    7 + quoteOverlap,
  );
  static const int quoteMaxLines = 2;
  static const double quoteThumbnail = 34;
  static const double quoteThumbnailRadius = sm;

  /// Reply caption ("Anna replied to you") above the quote.
  static const EdgeInsets captionPadding = EdgeInsets.fromLTRB(6, 0, 6, 3);

  /// Backdrop chip behind caption and time over a wallpaper.
  static const EdgeInsets metaChipPadding = EdgeInsets.symmetric(
    horizontal: 6,
    vertical: 1,
  );
  static const double metaChipOpacity = .8;

  static const double avatarSlot = 36;
  static const double avatar = 28;
  static const double maxWidthFraction = .78;

  /// Media (images, videos, reels, files, voice) fill the bubble's width up
  /// to this cap, so wide screens do not show poster-sized thumbnails.
  static const double mediaMaxWidth = 360;

  /// Instagram share previews occupy two thirds of the ordinary media width.
  static const double shareWidthFraction = 2 / 3;

  /// Height/width limits of a media frame: taller media (9:16 reels) is
  /// cropped to 3:4, wider media (panoramas) to 5:2, like Messenger.
  static const double mediaMaxAspect = 4 / 3;
  static const double mediaMinAspect = .4;

  /// A media frame never takes more than this share of the viewport height.
  static const double mediaMaxViewportFraction = .6;

  static const double sm = NotionSpace.sm;
  static const double xs = NotionSpace.xs;
}

/// Typography scale. Styles are colourless: text inherits the theme colour;
/// use [NotionColors.textSecondary] or [NotionTypography] for muted text.
abstract final class NotionType {
  /// Bundled in assets/notion/fonts; set explicitly so component styles
  /// (buttons, list tiles) never fall back to the platform font.
  static const family = 'Roboto';

  /// Badges and dense timestamps.
  static const micro = TextStyle(fontFamily: family, fontSize: 11, height: 1.3);

  /// Metadata, helper text, section labels.
  static const caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.4,
  );

  /// Row subtitles and secondary lines.
  static const footnote = TextStyle(
    fontFamily: family,
    fontSize: 13,
    height: 1.4,
  );

  /// Dense body: property labels, menus, dialogs.
  static const callout = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.4,
  );

  /// Default reading size: row titles, messages.
  static const body = TextStyle(fontFamily: family, fontSize: 16, height: 1.4);
  static const bodyStrong = TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  /// Header bars and dialog titles.
  static const headline = TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// Section headings inside a page.
  static const heading = TextStyle(
    fontFamily: family,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// Page title (one per screen).
  static const title = TextStyle(
    fontFamily: family,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    height: 1.15,
  );
}

/// Colours drawn over video frames (round videos, media stage). Video content
/// is arbitrary, so these stay black/white in both themes instead of following
/// [NotionColors].
abstract final class NotionMediaColors {
  /// Pill and glyph backing over a frame (45 % black).
  static const scrim = Color(0x73000000);

  /// Barrier behind an enlarged video; white controls sit on it (72 % black).
  static const stageScrim = Color(0xB8000000);

  /// Backdrop of the full-screen photo/video viewer (95 % black, like
  /// Telegram and Messenger); fades with the route and a dismiss swipe.
  static const viewer = Color(0xF2000000);

  /// Text, icons and rings on [scrim] / [stageScrim].
  static const onScrim = Color(0xFFFFFFFF);
}

/// Semantic colours. Never reference the hex values directly in UI code.
@immutable
class NotionColors {
  /// Page background.
  final Color background;

  /// Cards, menus, input fills, incoming surfaces.
  final Color surface;

  /// Selected rows, pressed states, highest container.
  final Color selected;

  /// Dividers, outlines, input borders.
  final Color border;

  /// Primary text and icons.
  final Color text;

  /// Labels, subtitles, metadata.
  final Color textSecondary;

  /// Placeholder and disabled text.
  final Color textTertiary;

  /// Page cover band behind the title.
  final Color cover;

  /// User accent as a foreground on the page (links, active icons, the
  /// typing line); at least 4.5:1 on [background]. Equals [text] for the
  /// Graphite preset. Filled accent controls use `NotionPalette.accentFill`.
  final Color accent;
  final Color onAccent;

  final Color danger;
  final Color success;
  final Color warning;
  final Color info;

  /// Modal barrier behind dialogs and sheets.
  final Color scrim;

  const NotionColors({
    required this.background,
    required this.surface,
    required this.selected,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.cover,
    required this.accent,
    required this.onAccent,
    required this.danger,
    required this.success,
    required this.warning,
    required this.info,
    required this.scrim,
  });

  static const dark = NotionColors(
    background: Color(0xFF191919),
    surface: Color(0xFF252525),
    selected: Color(0xFF2F2F2F),
    border: Color(0xFF383838),
    text: Color(0xFFE8E7E5),
    textSecondary: Color(0xFFAAAAA5),
    textTertiary: Color(0xFF7F7F7B),
    cover: Color(0xFF33312B),
    accent: Color(0xFFE8E7E5),
    onAccent: Color(0xFF191919),
    danger: Color(0xFFDF5452),
    success: Color(0xFF529E72),
    warning: Color(0xFFCA9849),
    info: Color(0xFF379AD3),
    scrim: Color(0x99000000),
  );

  /// Pure black dark theme (OLED screens): the page is black, raised
  /// surfaces step up from it; text and status roles stay as in [dark].
  static const black = NotionColors(
    background: Color(0xFF000000),
    surface: Color(0xFF141414),
    selected: Color(0xFF1F1F1F),
    border: Color(0xFF2C2C2C),
    text: Color(0xFFE8E7E5),
    textSecondary: Color(0xFFAAAAA5),
    textTertiary: Color(0xFF7F7F7B),
    cover: Color(0xFF26241F),
    accent: Color(0xFFE8E7E5),
    onAccent: Color(0xFF000000),
    danger: Color(0xFFDF5452),
    success: Color(0xFF529E72),
    warning: Color(0xFFCA9849),
    info: Color(0xFF379AD3),
    scrim: Color(0xB3000000),
  );

  static const light = NotionColors(
    background: Color(0xFFFAF9F6),
    surface: Color(0xFFF0EFEB),
    selected: Color(0xFFE8E7E3),
    border: Color(0xFFD6D5D0),
    text: Color(0xFF242424),
    textSecondary: Color(0xFF65655F),
    textTertiary: Color(0xFF91918E),
    cover: Color(0xFFEEEAE0),
    accent: Color(0xFF242424),
    onAccent: Color(0xFFFAF9F6),
    danger: Color(0xFFD44C47),
    success: Color(0xFF448361),
    warning: Color(0xFFD9730D),
    info: Color(0xFF337EA9),
    scrim: Color(0x66000000),
  );

  NotionColors copyWith({Color? accent, Color? onAccent}) => NotionColors(
    background: background,
    surface: surface,
    selected: selected,
    border: border,
    text: text,
    textSecondary: textSecondary,
    textTertiary: textTertiary,
    cover: cover,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    danger: danger,
    success: success,
    warning: warning,
    info: info,
    scrim: scrim,
  );

  static NotionColors lerp(NotionColors a, NotionColors b, double t) {
    Color l(Color x, Color y) => Color.lerp(x, y, t)!;
    return NotionColors(
      background: l(a.background, b.background),
      surface: l(a.surface, b.surface),
      selected: l(a.selected, b.selected),
      border: l(a.border, b.border),
      text: l(a.text, b.text),
      textSecondary: l(a.textSecondary, b.textSecondary),
      textTertiary: l(a.textTertiary, b.textTertiary),
      cover: l(a.cover, b.cover),
      accent: l(a.accent, b.accent),
      onAccent: l(a.onAccent, b.onAccent),
      danger: l(a.danger, b.danger),
      success: l(a.success, b.success),
      warning: l(a.warning, b.warning),
      info: l(a.info, b.info),
      scrim: l(a.scrim, b.scrim),
    );
  }
}

/// [NotionType] styles with the theme's colours applied.
@immutable
class NotionTypography {
  final TextStyle micro;
  final TextStyle caption;
  final TextStyle footnote;
  final TextStyle callout;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle headline;
  final TextStyle heading;
  final TextStyle title;

  /// Muted variants for labels and metadata.
  final TextStyle captionMuted;
  final TextStyle footnoteMuted;
  final TextStyle calloutMuted;

  /// Uppercase-free section label above grouped rows.
  final TextStyle sectionLabel;

  const NotionTypography({
    required this.micro,
    required this.caption,
    required this.footnote,
    required this.callout,
    required this.body,
    required this.bodyStrong,
    required this.headline,
    required this.heading,
    required this.title,
    required this.captionMuted,
    required this.footnoteMuted,
    required this.calloutMuted,
    required this.sectionLabel,
  });

  factory NotionTypography.of(NotionColors colors) => NotionTypography(
    micro: NotionType.micro.copyWith(color: colors.textSecondary),
    caption: NotionType.caption.copyWith(color: colors.text),
    footnote: NotionType.footnote.copyWith(color: colors.text),
    callout: NotionType.callout.copyWith(color: colors.text),
    body: NotionType.body.copyWith(color: colors.text),
    bodyStrong: NotionType.bodyStrong.copyWith(color: colors.text),
    headline: NotionType.headline.copyWith(color: colors.text),
    heading: NotionType.heading.copyWith(color: colors.text),
    title: NotionType.title.copyWith(color: colors.text),
    captionMuted: NotionType.caption.copyWith(color: colors.textSecondary),
    footnoteMuted: NotionType.footnote.copyWith(color: colors.textSecondary),
    calloutMuted: NotionType.callout.copyWith(color: colors.textSecondary),
    sectionLabel: NotionType.caption.copyWith(
      color: colors.textSecondary,
      fontWeight: FontWeight.w500,
    ),
  );

  static NotionTypography lerp(
    NotionTypography a,
    NotionTypography b,
    double t,
  ) {
    TextStyle l(TextStyle x, TextStyle y) => TextStyle.lerp(x, y, t)!;
    return NotionTypography(
      micro: l(a.micro, b.micro),
      caption: l(a.caption, b.caption),
      footnote: l(a.footnote, b.footnote),
      callout: l(a.callout, b.callout),
      body: l(a.body, b.body),
      bodyStrong: l(a.bodyStrong, b.bodyStrong),
      headline: l(a.headline, b.headline),
      heading: l(a.heading, b.heading),
      title: l(a.title, b.title),
      captionMuted: l(a.captionMuted, b.captionMuted),
      footnoteMuted: l(a.footnoteMuted, b.footnoteMuted),
      calloutMuted: l(a.calloutMuted, b.calloutMuted),
      sectionLabel: l(a.sectionLabel, b.sectionLabel),
    );
  }
}

/// Glass values (DESIGN.md "Glass"): the language of the floating dock.
///
/// Real blur is for fixed chrome (header, dock, composer) and settled
/// overlays (menus, popovers, dialogs, sheets). Anything inside a scrolling
/// list uses the opaque roles plus the [border] hairline instead.
@immutable
class NotionGlass {
  /// Translucent fill of header and composer bars (background ~60%).
  final Color tint;

  /// Translucent fill of the floating dock (surface ~58%).
  final Color dockTint;

  /// Hairline drawn around the dock, overlays and under translucent bars.
  final Color border;

  /// Gaussian blur applied to the content behind the bar.
  final double blurSigma;

  final Color? _overlayTint;

  const NotionGlass({
    required this.tint,
    required this.dockTint,
    required this.border,
    this.blurSigma = 18,
    // A named parameter cannot be private; the getter supplies the fallback.
    Color? overlayTint,
    // ignore: prefer_initializing_formals
  }) : _overlayTint = overlayTint;

  /// Fill of menus, popovers, dialogs and sheets: the dock tone, denser so
  /// text stays readable over any content (surface ~84% dark, ~90% light).
  Color get overlayTint => _overlayTint ?? dockTint.withValues(alpha: .86);

  /// Floating dock radius.
  static const BorderRadius dockRadius = NotionRadius.pillAll;

  /// Menus and popovers (the network selector).
  static const BorderRadius panelRadius = NotionRadius.lgAll;

  /// Dialogs.
  static const BorderRadius dialogRadius = NotionRadius.xlAll;

  /// Bottom sheets (top corners only).
  static const BorderRadius sheetRadius = NotionRadius.sheetTop;

  /// Distance of floating glass (dock, snackbars, pills) from screen edges.
  static const double floatingInset = NotionSpace.md;

  static const dark = NotionGlass(
    tint: Color(0x99191919),
    dockTint: Color(0x94252525),
    border: Color(0x1AFFFFFF),
    overlayTint: Color(0xD6252525),
  );

  /// Glass over the pure black theme ([NotionColors.black]).
  static const black = NotionGlass(
    tint: Color(0x99000000),
    dockTint: Color(0x94141414),
    border: Color(0x1AFFFFFF),
    overlayTint: Color(0xD6141414),
  );

  /// Light paper needs a denser fill (~72%) to keep text contrast.
  static const light = NotionGlass(
    tint: Color(0xB8FAF9F6),
    dockTint: Color(0xB8F0EFEB),
    border: Color(0x14000000),
    overlayTint: Color(0xE6F0EFEB),
  );

  static NotionGlass lerp(NotionGlass a, NotionGlass b, double t) =>
      NotionGlass(
        tint: Color.lerp(a.tint, b.tint, t)!,
        dockTint: Color.lerp(a.dockTint, b.dockTint, t)!,
        border: Color.lerp(a.border, b.border, t)!,
        blurSigma: a.blurSigma + (b.blurSigma - a.blurSigma) * t,
        overlayTint: Color.lerp(a.overlayTint, b.overlayTint, t),
      );
}

/// Theme-dependent Notion tokens registered on [ThemeData.extensions].
///
/// Read them with `context.notion.colors` / `context.notion.typography`.
/// The theme-independent scales are const: [NotionSpace], [NotionRadius],
/// [NotionSize], [NotionType].
///
/// The static members below are the frozen v1 API (dark values only). They
/// stay for the transition; new code must use `context.notion` so that the
/// light theme and accent preference keep working.
@immutable
class NotionTokens extends ThemeExtension<NotionTokens> {
  final NotionColors colors;
  final NotionTypography typography;
  final NotionGlass glass;

  /// Accent and intensity roles (DESIGN.md "Colour system"): bubble fill,
  /// accent fills and tints, letter avatars, network marks.
  final NotionPalette palette;

  NotionTokens({
    required this.colors,
    NotionTypography? typography,
    this.glass = NotionGlass.dark,
    NotionPalette? palette,
  }) : typography = typography ?? NotionTypography.of(colors),
       palette =
           palette ??
           (identical(glass, NotionGlass.light)
               ? NotionPalette.legacyLight
               : NotionPalette.legacyDark);

  static final dark = NotionTokens(colors: NotionColors.dark);
  static final light = NotionTokens(
    colors: NotionColors.light,
    glass: NotionGlass.light,
  );

  static NotionTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NotionTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  NotionTokens copyWith({
    NotionColors? colors,
    NotionTypography? typography,
    NotionGlass? glass,
    NotionPalette? palette,
  }) => NotionTokens(
    colors: colors ?? this.colors,
    typography: typography ?? (colors == null ? this.typography : null),
    glass: glass ?? this.glass,
    palette: palette ?? this.palette,
  );

  @override
  NotionTokens lerp(covariant NotionTokens? other, double t) {
    if (other == null) return this;
    return NotionTokens(
      colors: NotionColors.lerp(colors, other.colors, t),
      typography: NotionTypography.lerp(typography, other.typography, t),
      glass: NotionGlass.lerp(glass, other.glass, t),
      palette: NotionPalette.lerp(palette, other.palette, t),
    );
  }

  // Transitional static API (v1). Dark palette only.
  static const background = Color(0xFF191919);
  static const surface = Color(0xFF252525);
  static const selected = Color(0xFF2F2F2F);
  static const border = Color(0xFF383838);
  static const text = Color(0xFFE8E7E5);
  static const secondary = Color(0xFFAAAAA5);
  static const cover = Color(0xFF33312B);
  static const double inset = NotionSpace.inset;
  static const double avatarRadius = NotionRadius.avatar;
  static const double radius = NotionRadius.md;
  static const double headerHeight = NotionSize.headerHeight;
  static const double touchTarget = NotionSize.touchTarget;
  static const title = NotionType.title;
  static const heading = NotionType.heading;
  static const body = NotionType.body;
  static const caption = NotionType.caption;
}

extension NotionContext on BuildContext {
  /// Active Notion tokens; falls back to the brightness default outside
  /// [NotionTheme].
  NotionTokens get notion => NotionTokens.of(this);
}
