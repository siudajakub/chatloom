// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_appearance_preview.dart';
import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_style.dart';

/// Live chat preview, background and message styles, then app appearance
/// and layout settings.
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
              const NotionSectionHeader(title: 'Chat appearance'),
              ExcludeSemantics(
                child: ChatAppearancePreview(
                  background: ChatBackground(
                    client: client,
                    selection: resolveChatBackground(
                      context,
                      controller.wallpaperPreview,
                      display: controller.displayPreferences,
                    ),
                  ),
                ),
              ),
              _WallpaperSection(controller: controller),
              NotionPickerRow<NotionBubbleFinish>(
                label: 'Outgoing bubbles',
                icon: Icons.chat_bubble_outline,
                value: controller.displayPreferences.bubbleFinish,
                options: [
                  for (final finish in NotionBubbleFinish.values)
                    NotionChoice(finish, finish.label),
                ],
                onChanged: (finish) => controller.setDisplayPreferences(
                  controller.displayPreferences.copyWith(bubbleFinish: finish),
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
                onCustom: controller.pickCustomAccent,
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
              _DisplayToggle(
                label: 'Pure black',
                subtitle: 'A black dark theme for OLED screens',
                selected: controller.displayPreferences.trueBlack,
                onChanged: (v) => controller.setDisplayPreferences(
                  controller.displayPreferences.copyWith(trueBlack: v),
                ),
              ),
              _DisplaySettings(controller: controller),
            ],
          ),
        ),
      ],
    );
  }
}

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
  final VoidCallback onCustom;
  const _AccentSwatches({
    required this.appearance,
    required this.onSelected,
    required this.onCustom,
  });

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
            label: accent.label,
            selected: appearance.custom == null && accent == appearance.accent,
            palette: NotionPalette.resolve(
              appearance.copyWith(accent: accent, clearCustom: true),
              tokens.colors,
              brightness,
            ),
            onTap: () => onSelected(accent),
          ),
        // Any colour: the picker's hue goes through the same contrast
        // tuning as the presets.
        _AccentSwatch(
          label: 'Custom',
          selected: appearance.custom != null,
          palette: appearance.custom == null
              ? null
              : NotionPalette.resolve(appearance, tokens.colors, brightness),
          onTap: onCustom,
        ),
      ],
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  final String label;
  final bool selected;

  /// Null draws the empty "Custom" swatch (a colour-picker icon).
  final NotionPalette? palette;
  final VoidCallback onTap;
  const _AccentSwatch({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    // Vivid shows the bubble gradient; the other intensities the fill that
    // badges, toggles and the send button take.
    final palette = this.palette;
    final gradient = palette?.bubbleGradient;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label accent',
      excludeSemantics: true,
      child: Tooltip(
        message: label,
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
                      color: palette == null
                          ? tokens.colors.surface
                          : gradient == null
                          ? palette.accentFill
                          : null,
                      border: palette == null
                          ? Border.all(color: tokens.colors.border)
                          : null,
                      gradient: gradient == null
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: gradient,
                            ),
                    ),
                    child: palette == null
                        ? Icon(
                            Icons.colorize_outlined,
                            size: NotionSize.iconSm,
                            color: tokens.colors.textSecondary,
                          )
                        : NotionPop(
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

  Future<void> _chooseBackground(BuildContext context) async {
    final prefs = controller.displayPreferences;
    final usingPhoto =
        controller.wallpaperUrl != null && prefs.accountWallpaperEnabled;
    var selected = usingPhoto ? null : prefs.wallpaperPreset;
    final choice = await showNotionSheet<NotionWallpaperPreset>(
      context: context,
      title: 'Chat background',
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ChatAppearancePreview(
                      background: ChatBackground(
                        selection: resolveChatBackground(
                          context,
                          controller.wallpaperPreview,
                          display: selected == null
                              ? prefs
                              : prefs.copyWith(
                                  wallpaperPreset: selected,
                                  accountWallpaperEnabled: false,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: NotionSpace.md),
                    NotionWallpaperGallery(
                      selected: selected,
                      strength: prefs.wallpaperStrength,
                      onSelected: (preset) => setState(() => selected = preset),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: NotionSpace.md),
            NotionButton.primary(
              label: 'Apply background',
              onPressed: selected == null
                  ? null
                  : () => Navigator.of(context).pop(selected),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted || !controller.mounted) return;
    await controller.setDisplayPreferences(
      controller.displayPreferences.copyWith(
        wallpaperPreset: choice,
        accountWallpaperEnabled: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = controller.displayPreferences;
    final hasPhoto = controller.wallpaperUrl != null;
    final usingPhoto = hasPhoto && prefs.accountWallpaperEnabled;
    final busy = controller.wallpaperBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: const Icon(Icons.wallpaper_outlined),
          title: 'Chat background',
          subtitle: usingPhoto ? 'Account photo' : prefs.wallpaperPreset.label,
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : () => _chooseBackground(context),
        ),
        if (!usingPhoto && prefs.wallpaperPreset != NotionWallpaperPreset.none)
          _SliderRow(
            label: 'Background strength',
            value: prefs.wallpaperStrength,
            min: .15,
            max: 1,
            divisions: 17,
            valueLabel: '${(prefs.wallpaperStrength * 100).round()}%',
            onChanged: (strength) => controller.setDisplayPreferences(
              controller.displayPreferences.copyWith(
                wallpaperStrength: strength,
              ),
            ),
            onChangeEnd: (_) {},
          ),
        if (hasPhoto && !usingPhoto)
          NotionListRow(
            leading: const Icon(Icons.image_outlined),
            title: 'Use saved photo',
            onTap: busy
                ? null
                : () => controller.setDisplayPreferences(
                    controller.displayPreferences.copyWith(
                      accountWallpaperEnabled: true,
                    ),
                  ),
          ),
        NotionListRow(
          leading: const Icon(Icons.add_photo_alternate_outlined),
          title: hasPhoto ? 'Change photo' : 'Choose photo',
          subtitle: hasPhoto ? null : 'Saved to your account',
          trailing: busy ? const NotionDelayedSpinner() : null,
          onTap: busy ? null : controller.setWallpaper,
        ),
        if (usingPhoto) ...[
          _SliderRow(
            label: 'Photo opacity',
            value: controller.wallpaperOpacity,
            min: 0,
            max: 1,
            divisions: 20,
            valueLabel: '${(controller.wallpaperOpacity * 100).round()}%',
            onChanged: controller.updateWallpaperOpacity,
            onChangeEnd: controller.saveWallpaperOpacity,
          ),
          _SliderRow(
            label: 'Photo blur',
            value: controller.wallpaperBlur,
            min: 0,
            max: 10,
            divisions: 10,
            valueLabel: controller.wallpaperBlur.round().toString(),
            onChanged: controller.updateWallpaperBlur,
            onChangeEnd: controller.saveWallpaperBlur,
          ),
          NotionListRow(
            leading: const Icon(Icons.delete_outline),
            title: 'Remove saved wallpaper',
            onTap: busy ? null : controller.removeWallpaper,
          ),
        ],
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
  final String? valueLabel;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.valueLabel,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: NotionSpace.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          valueLabel == null ? label : '$label · $valueLabel',
          style: context.notion.typography.calloutMuted,
        ),
        Semantics(
          label: label,
          child: Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value,
            label: valueLabel,
            semanticFormatterCallback: (d) =>
                valueLabel ?? d.toStringAsFixed(1),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    ),
  );
}

/// A setting row with a switch; the whole row toggles.
class _DisplayToggle extends StatelessWidget {
  const _DisplayToggle({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => NotionListRow(
    title: label,
    subtitle: subtitle,
    onTap: () => onChanged(!selected),
    trailing: Semantics(
      label: label,
      child: Switch(value: selected, onChanged: onChanged),
    ),
  );
}

/// Presentation controls use the same preferences and production presenters
/// as the live preview. Defaults restore only these local visual choices.
class _DisplaySettings extends StatelessWidget {
  const _DisplaySettings({required this.controller});
  final SettingsStyleController controller;

  @override
  Widget build(BuildContext context) {
    final value = controller.displayPreferences;
    void update(NotionDisplayPreferences next) =>
        controller.setDisplayPreferences(next);
    Widget toggle(
      String label,
      String subtitle,
      bool selected,
      ValueChanged<bool> onChanged,
    ) => _DisplayToggle(
      label: label,
      subtitle: subtitle,
      selected: selected,
      onChanged: onChanged,
    );
    Widget slider(
      String label,
      double selected,
      double min,
      double max,
      int divisions,
      ValueChanged<double> onChanged, {
      bool percentage = true,
    }) => _SliderRow(
      label: label,
      value: selected,
      min: min,
      max: max,
      divisions: divisions,
      valueLabel: percentage
          ? '${(selected * 100).round()}%'
          : selected.round().toString(),
      onChanged: onChanged,
      onChangeEnd: (_) {},
    );
    Widget picker<T>(
      String label,
      String? subtitle,
      T selected,
      List<NotionChoice<T>> options,
      ValueChanged<T> onChanged,
    ) => NotionPickerRow<T>(
      key: ValueKey('appearance_$label'),
      label: label,
      subtitle: subtitle,
      value: selected,
      options: options,
      onChanged: onChanged,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Text'),
        slider(
          'Interface text size',
          value.uiTextScale,
          .85,
          1.3,
          9,
          (v) => update(value.copyWith(uiTextScale: v)),
        ),
        slider(
          'Message text size',
          value.messageTextScale,
          .85,
          1.4,
          11,
          (v) => update(value.copyWith(messageTextScale: v)),
        ),
        picker<NotionJumboEmoji>(
          'Emoji-only messages',
          'Size of a message that is a single emoji',
          value.jumboEmoji,
          [for (final o in NotionJumboEmoji.values) NotionChoice(o, o.label)],
          (v) => update(value.copyWith(jumboEmoji: v)),
        ),
        picker<NotionClockFormat>(
          'Clock',
          'Times in chats, the chat list and reminders',
          value.clockFormat,
          [for (final o in NotionClockFormat.values) NotionChoice(o, o.label)],
          (v) => update(value.copyWith(clockFormat: v)),
        ),
        const NotionSectionHeader(title: 'Chat list'),
        slider(
          'Row size',
          value.inboxScale,
          .65,
          1,
          7,
          (v) => update(value.copyWith(inboxScale: v)),
        ),
        toggle(
          'Avatars',
          'Show contact pictures in the chat list',
          value.inboxAvatars,
          (v) => update(value.copyWith(inboxAvatars: v)),
        ),
        toggle(
          'Message previews',
          'Show the latest message below each name',
          value.inboxPreviews,
          (v) => update(value.copyWith(inboxPreviews: v)),
        ),
        toggle(
          'Two-line previews',
          'Show more of the latest message',
          value.inboxPreviewLines > 1,
          (v) => update(value.copyWith(inboxPreviewLines: v ? 2 : 1)),
        ),
        toggle(
          'Network badges',
          'Show which network each chat uses',
          value.inboxNetworkBadges,
          (v) => update(value.copyWith(inboxNetworkBadges: v)),
        ),
        toggle(
          'Timestamps',
          'Show the time of the latest message',
          value.inboxTimestamps,
          (v) => update(value.copyWith(inboxTimestamps: v)),
        ),
        toggle(
          'Unread highlights',
          'Tint unread chats; counts remain visible',
          value.inboxUnreadHighlight,
          (v) => update(value.copyWith(inboxUnreadHighlight: v)),
        ),
        const NotionSectionHeader(title: 'Conversations'),
        slider(
          'Message spacing',
          value.messageSpacing,
          .75,
          1.5,
          15,
          (v) => update(value.copyWith(messageSpacing: v)),
        ),
        slider(
          'Bubble width',
          value.bubbleWidth,
          .6,
          .95,
          35,
          (v) => update(value.copyWith(bubbleWidth: v)),
        ),
        slider(
          'Bubble corners',
          value.bubbleRadius,
          6,
          28,
          22,
          (v) => update(value.copyWith(bubbleRadius: v)),
          percentage: false,
        ),
        picker<NotionTimestampMode>(
          'Message times',
          'Which messages show their time',
          value.messageTimestamps,
          [
            for (final o in NotionTimestampMode.values)
              NotionChoice(o, o.label),
          ],
          (v) => update(value.copyWith(messageTimestamps: v)),
        ),
        toggle(
          'Sender avatars',
          'Show pictures beside incoming messages and typing',
          value.messageAvatars,
          (v) => update(value.copyWith(messageAvatars: v)),
        ),
        toggle(
          'Sender names',
          'Show who wrote each message in groups',
          value.senderNames,
          (v) => update(value.copyWith(senderNames: v)),
        ),
        toggle(
          'Delivery and read indicators',
          'Show delivery status and who has seen your messages',
          value.deliveryTicks,
          (v) => update(value.copyWith(deliveryTicks: v)),
        ),
        const NotionSectionHeader(title: 'Effects'),
        toggle(
          'Reduce motion',
          'Use still transitions and typing dots',
          value.reduceMotion,
          (v) => update(value.copyWith(reduceMotion: v)),
        ),
        toggle(
          'Glass effects',
          'Use translucent headers, menus and the dock',
          value.glassEnabled,
          (v) => update(value.copyWith(glassEnabled: v)),
        ),
        toggle(
          'Haptic feedback',
          'Vibrate lightly on sends, long presses and swipes',
          value.haptics,
          (v) => update(value.copyWith(haptics: v)),
        ),
        NotionListRow(
          leading: const Icon(Icons.restore),
          title: 'Reset layout and effects',
          subtitle:
              'Restore text, chat list, conversation and background '
              'defaults; colours stay',
          trailing: const Icon(Icons.chevron_right),
          onTap: value == NotionDisplayPreferences.standard
              ? null
              : controller.resetDisplayPreferences,
        ),
        NotionListRow(
          key: const Key('appearance_reset_colours'),
          leading: const Icon(Icons.format_color_reset_outlined),
          title: 'Reset colours',
          subtitle: 'Back to the blue accent at balanced intensity',
          trailing: const Icon(Icons.chevron_right),
          onTap: controller.appearance == NotionAppearance.standard
              ? null
              : controller.resetAppearance,
        ),
      ],
    );
  }
}

/// The custom accent picker: hue and saturation sliders over a live
/// swatch and a sample own bubble in the resulting palette. Returns the
/// colour, or null when dismissed.
Future<Color?> showCustomAccentSheet(
  BuildContext context, {
  required Color initial,
}) {
  final start = HSLColor.fromColor(initial);
  var hue = start.hue;
  var saturation = start.saturation.clamp(.35, 1.0);
  return showNotionSheet<Color>(
    context: context,
    title: 'Custom accent',
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final tokens = context.notion;
        final color = HSLColor.fromAHSL(1, hue, saturation, .5).toColor();
        final palette = NotionPalette.resolve(
          tokens.palette.appearance.copyWith(custom: color),
          tokens.colors,
          Theme.of(context).brightness,
        );
        final theme = Theme.of(context);
        final bubbles = ConversationBubbleColors.of(context).withPalette(
          palette,
          finish: NotionDisplayPreferences.of(context).bubbleFinish,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Theme(
              data: theme.copyWith(
                extensions: [
                  ...theme.extensions.values.where(
                    (extension) => extension is! ConversationBubbleColors,
                  ),
                  bubbles,
                ],
              ),
              child: const ConversationBubble(
                outgoing: true,
                body: Text(
                  'Your messages look like this',
                  style: NotionType.body,
                ),
              ),
            ),
            _SliderRow(
              label: 'Hue',
              value: hue,
              min: 0,
              max: 359,
              divisions: 359,
              valueLabel: '${hue.round()}°',
              onChanged: (v) => setState(() => hue = v),
              onChangeEnd: (_) {},
            ),
            _SliderRow(
              label: 'Saturation',
              value: saturation,
              min: .35,
              max: 1,
              divisions: 13,
              valueLabel: '${(saturation * 100).round()}%',
              onChanged: (v) => setState(() => saturation = v),
              onChangeEnd: (_) {},
            ),
            const SizedBox(height: NotionSpace.sm),
            NotionButton.primary(
              key: const Key('custom_accent_apply'),
              expand: true,
              label: 'Use this colour',
              onPressed: () => Navigator.of(context).pop(color),
            ),
          ],
        );
      },
    ),
  );
}
