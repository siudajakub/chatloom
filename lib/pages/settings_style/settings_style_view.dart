// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_style.dart';

/// Appearance, Notion style: a live preview, then colour intensity, accent,
/// theme and wallpaper. Every choice applies at once.
class SettingsStyleView extends StatelessWidget {
  final SettingsStyleController controller;

  const SettingsStyleView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final appearance = controller.appearance;
    return NotionScaffold(
      title: 'Appearance',
      onBack: ChatLoomThemes.isColumnMode(context)
          ? null
          : () => Navigator.of(context).maybePop(),
      children: [
        // Wallpaper changes arrive as account data; only this part listens.
        StreamBuilder(
          stream: client.onSync.stream.where(
            (update) =>
                update.accountData?.any(
                  (data) =>
                      data.type ==
                      ApplicationAccountConfigExtension.accountDataKey,
                ) ??
                false,
          ),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The preview builds bubbles, an inbox row and maybe a
              // wallpaper; keep it out of the page transition. Same height
              // before and after, so nothing below moves when it appears.
              AfterRouteTransition(
                placeholder: const SizedBox(height: _previewMinHeight),
                child: _AppearancePreview(
                  wallpaper: controller.wallpaperUrl,
                  opacity: controller.wallpaperOpacity,
                  blur: controller.wallpaperBlur,
                ),
              ),
              const NotionSectionHeader(title: 'Colour intensity'),
              _IntensitySelector(
                appearance: appearance,
                onSelected: controller.setIntensity,
              ),
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.xs),
                child: NotionFadeThrough(
                  child: Text(
                    appearance.intensity.description,
                    key: ValueKey(appearance.intensity),
                    style: context.notion.typography.footnoteMuted,
                  ),
                ),
              ),
              const NotionSectionHeader(title: 'Accent colour'),
              _AccentSwatches(
                appearance: appearance,
                onSelected: controller.setAccent,
              ),
              const NotionSectionHeader(title: 'Theme'),
              SegmentedButton<ThemeMode>(
                selected: {controller.currentTheme},
                showSelectedIcon: false,
                onSelectionChanged: (selected) =>
                    controller.switchTheme(selected.single),
                segments: [
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(L10n.of(context).darkTheme),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(L10n.of(context).lightTheme),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(L10n.of(context).systemTheme),
                  ),
                ],
              ),
              const NotionSectionHeader(title: 'Chat wallpaper'),
              _WallpaperSection(controller: controller),
            ],
          ),
        ),
      ],
    );
  }
}

/// The preview's height at text scale 1 on a phone, so the placeholder and
/// the built preview take the same room.
const double _previewMinHeight = 300;

/// A sample inbox row and conversation drawn with the real presenters
/// ([NotionInboxRow], [ConversationBubble]), so it shows exactly what the
/// chosen colours do: avatars, unread badge, incoming and own bubbles.
class _AppearancePreview extends StatelessWidget {
  final Uri? wallpaper;
  final double opacity;
  final double blur;
  const _AppearancePreview({
    required this.wallpaper,
    required this.opacity,
    required this.blur,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    Widget text(String value) => Text(value, style: NotionType.body);
    final wallpaper = this.wallpaper;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _previewMinHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.colors.background,
              borderRadius: NotionRadius.lgAll,
              border: Border.all(color: tokens.colors.border),
            ),
            child: ClipRRect(
              borderRadius: NotionRadius.lgAll,
              child: Stack(
                children: [
                  if (wallpaper != null)
                    Positioned.fill(
                      child: ChatWallpaper(
                        uri: wallpaper,
                        opacity: opacity,
                        blur: blur,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NotionSpace.sm,
                      NotionSpace.xxs,
                      NotionSpace.sm,
                      NotionSpace.sm,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        NotionInboxRow(
                          avatar: const NotionInitialAvatar(name: 'Anna Lis'),
                          name: 'Anna Lis',
                          preview: 'Sed diam nonumy eirmod tempor',
                          time: '12:04',
                          unreadCount: 2,
                          onTap: _noop,
                        ),
                        Divider(color: tokens.colors.border),
                        const ConversationBubble(
                          outgoing: false,
                          groupPosition: ConversationGroupPosition.first,
                          body: Text(
                            'Lorem ipsum dolor sit amet',
                            style: NotionType.body,
                          ),
                        ),
                        ConversationBubble(
                          outgoing: false,
                          groupPosition: ConversationGroupPosition.last,
                          avatar: const NotionInitialAvatar(
                            name: 'Anna Lis',
                            size: NotionBubble.avatar,
                          ),
                          body: text('Consetetur sadipscing elitr?'),
                        ),
                        ConversationBubble(
                          outgoing: true,
                          groupPosition: ConversationGroupPosition.first,
                          body: text('At vero eos et accusam'),
                        ),
                        ConversationBubble(
                          outgoing: true,
                          groupPosition: ConversationGroupPosition.last,
                          body: text('Stet clita kasd gubergren'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _noop() {}

/// Three cards, each showing its own pair of mini bubbles in that intensity.
class _IntensitySelector extends StatelessWidget {
  final NotionAppearance appearance;
  final ValueChanged<NotionIntensity> onSelected;
  const _IntensitySelector({
    required this.appearance,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final brightness = Theme.of(context).brightness;
    return Row(
      spacing: NotionSpace.xs,
      children: [
        for (final intensity in NotionIntensity.values)
          Expanded(
            child: _IntensityOption(
              intensity: intensity,
              selected: intensity == appearance.intensity,
              palette: NotionPalette.resolve(
                appearance.copyWith(intensity: intensity),
                tokens.colors,
                brightness,
              ),
              onTap: () => onSelected(intensity),
            ),
          ),
      ],
    );
  }
}

/// Mini bubble size inside an intensity card.
const double _miniBubbleHeight = 14;
const double _miniIncomingWidth = 40;
const double _miniOutgoingWidth = 54;

class _IntensityOption extends StatelessWidget {
  final NotionIntensity intensity;
  final bool selected;
  final NotionPalette palette;
  final VoidCallback onTap;
  const _IntensityOption({
    required this.intensity,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final current = tokens.palette;
    final incoming = ConversationBubbleColors.of(context).incoming;
    final gradient = palette.bubbleGradient;
    return Semantics(
      button: true,
      selected: selected,
      label: '${intensity.label} colours. ${intensity.description}',
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressButton,
        child: AnimatedContainer(
          duration: NotionMotion.of(context, NotionMotion.quick),
          curve: NotionMotion.standard,
          decoration: BoxDecoration(
            color: selected ? current.accentTint : tokens.colors.surface,
            borderRadius: NotionRadius.mdAll,
            // Constant width, so selecting never shifts the content.
            border: Border.all(
              color: selected ? current.accent : tokens.colors.border,
              width: 2,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: NotionRadius.mdAll,
              child: Padding(
                padding: const EdgeInsets.all(NotionSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Container(
                        width: _miniIncomingWidth,
                        height: _miniBubbleHeight,
                        decoration: BoxDecoration(
                          color: incoming,
                          borderRadius: NotionRadius.pillAll,
                        ),
                      ),
                    ),
                    const SizedBox(height: NotionSpace.xxs),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Container(
                        width: _miniOutgoingWidth,
                        height: _miniBubbleHeight,
                        decoration: BoxDecoration(
                          color: gradient == null ? palette.bubble : null,
                          gradient: gradient == null
                              ? null
                              : LinearGradient(colors: gradient),
                          borderRadius: NotionRadius.pillAll,
                        ),
                      ),
                    ),
                    const SizedBox(height: NotionSpace.sm),
                    Text(
                      intensity.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: tokens.typography.callout.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Swatch diameter with its selection ring; each sits in a 48 pt touch
/// target. The colour disc is [_swatchRing] narrower (ring and gap).
const double _swatch = 38;
const double _swatchRing = 10;

class _AccentSwatches extends StatelessWidget {
  final NotionAppearance appearance;
  final ValueChanged<NotionAccent> onSelected;
  const _AccentSwatches({required this.appearance, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final brightness = Theme.of(context).brightness;
    return Wrap(
      spacing: NotionSpace.xxs,
      runSpacing: NotionSpace.xxs,
      children: [
        for (final accent in NotionAccent.values)
          _AccentSwatch(
            accent: accent,
            selected: accent == appearance.accent,
            palette: NotionPalette.resolve(
              appearance.copyWith(accent: accent),
              tokens.colors,
              brightness,
            ),
            onTap: () => onSelected(accent),
          ),
      ],
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  final NotionAccent accent;
  final bool selected;
  final NotionPalette palette;
  final VoidCallback onTap;
  const _AccentSwatch({
    required this.accent,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    // Vivid shows the bubble gradient; the other intensities the fill that
    // badges, toggles and the send button take.
    final gradient = palette.bubbleGradient;
    return Semantics(
      button: true,
      selected: selected,
      label: '${accent.label} accent',
      excludeSemantics: true,
      child: Tooltip(
        message: accent.label,
        child: NotionPressable(
          scale: NotionMotion.pressIcon,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: NotionSize.touchTarget,
              child: Center(
                child: AnimatedContainer(
                  duration: NotionMotion.of(context, NotionMotion.quick),
                  curve: NotionMotion.standard,
                  width: _swatch,
                  height: _swatch,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? tokens.colors.text : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Container(
                    width: _swatch - _swatchRing,
                    height: _swatch - _swatchRing,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: gradient == null ? palette.accentFill : null,
                      gradient: gradient == null
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: gradient,
                            ),
                    ),
                    child: NotionPop(
                      visible: selected,
                      child: Icon(
                        Icons.check,
                        size: NotionSize.iconSm,
                        color: palette.onAccentFill,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WallpaperSection extends StatelessWidget {
  final SettingsStyleController controller;
  const _WallpaperSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final hasWallpaper = controller.wallpaperUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: const Icon(Icons.wallpaper_outlined),
          title: hasWallpaper ? 'Change wallpaper' : 'Choose wallpaper',
          subtitle: 'Shown behind every conversation',
          trailing: controller.wallpaperBusy
              ? const NotionDelayedSpinner()
              : null,
          onTap: controller.wallpaperBusy ? null : controller.setWallpaper,
        ),
        NotionSizeReveal(
          visible: hasWallpaper,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NotionListRow(
                leading: Icon(Icons.delete_outline, color: colors.danger),
                title: 'Remove wallpaper',
                onTap: hasWallpaper ? controller.removeWallpaper : null,
              ),
              _SliderRow(
                label: L10n.of(context).opacity,
                value: controller.wallpaperOpacity.clamp(0.1, 1.0),
                min: 0.1,
                max: 1.0,
                divisions: 9,
                onChanged: controller.updateWallpaperOpacity,
                onChangeEnd: controller.saveWallpaperOpacity,
              ),
              _SliderRow(
                label: L10n.of(context).blur,
                value: controller.wallpaperBlur.clamp(0.0, 10.0),
                min: 0.0,
                max: 10.0,
                divisions: 10,
                onChanged: controller.updateWallpaperBlur,
                onChangeEnd: controller.saveWallpaperBlur,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: NotionSpace.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.notion.typography.calloutMuted),
        Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value,
          semanticFormatterCallback: (d) => d.toStringAsFixed(1),
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    ),
  );
}
