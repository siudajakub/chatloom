// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/pages/chat/events/state_message.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/color_value.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../config/app_config.dart';
import 'settings_style.dart';

class SettingsStyleView extends StatelessWidget {
  final SettingsStyleController controller;

  const SettingsStyleView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const colorPickerSize = 32.0;
    final client = Matrix.of(context).client;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !ChatLoomThemes.isColumnMode(context),
        centerTitle: false,
        title: const Text('Appearance'),
      ),
      backgroundColor: theme.colorScheme.surface,
      body: NotionSettingsBody(
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(NotionSpace.sm),
              child: SegmentedButton<ThemeMode>(
                selected: {controller.currentTheme},
                onSelectionChanged: (selected) =>
                    controller.switchTheme(selected.single),
                segments: [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(L10n.of(context).lightTheme),
                    icon: const Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(L10n.of(context).darkTheme),
                    icon: const Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(L10n.of(context).systemTheme),
                    icon: const Icon(Icons.auto_mode_outlined),
                  ),
                ],
              ),
            ),
            Divider(color: theme.dividerColor),
            ListTile(
              title: Text(
                L10n.of(context).setColorTheme,
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _ColorSwatches(controller: controller, size: colorPickerSize),
            Divider(color: theme.dividerColor),
            ListTile(
              title: Text(
                L10n.of(context).messagesStyle,
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            StreamBuilder(
              stream: client.onSync.stream.where(
                (syncUpdate) =>
                    syncUpdate.accountData?.any(
                      (accountData) =>
                          accountData.type ==
                          ApplicationAccountConfigExtension.accountDataKey,
                    ) ??
                    false,
              ),
              builder: (context, snapshot) {
                final accountConfig = client.applicationAccountConfig;

                return Column(
                  mainAxisSize: .min,
                  children: [
                    // The preview builds a synthetic room event, a blurred
                    // wallpaper and scaled text; keep it out of the frames
                    // of the page transition. Same minimum height before and
                    // after, so nothing below moves when it appears.
                    AfterRouteTransition(
                      placeholder: const SizedBox(height: _previewMinHeight),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: _previewMinHeight,
                        ),
                        child: MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            textScaler: TextScaler.linear(
                              AppSettings.fontSizeFactor.value,
                            ),
                          ),
                          child: AnimatedContainer(
                            duration: ChatLoomThemes.animationDuration,
                            curve: ChatLoomThemes.animationCurve,
                            decoration: const BoxDecoration(),
                            clipBehavior: Clip.hardEdge,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (accountConfig.wallpaperUrl != null)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity: controller.wallpaperOpacity,
                                      child: ImageFiltered(
                                        imageFilter: ImageFilter.blur(
                                          sigmaX: controller.wallpaperBlur,
                                          sigmaY: controller.wallpaperBlur,
                                        ),
                                        child: MxcImage(
                                          key: ValueKey(
                                            accountConfig.wallpaperUrl,
                                          ),
                                          uri: accountConfig.wallpaperUrl,
                                          fit: BoxFit.cover,
                                          isThumbnail: true,
                                          width: ChatLoomThemes.columnWidth * 2,
                                          height: _previewMinHeight,
                                        ),
                                      ),
                                    ),
                                  ),
                                Column(
                                  mainAxisSize: .min,
                                  children: [
                                    const SizedBox(height: NotionSpace.md),
                                    StateMessage(
                                      Event(
                                        eventId: 'style_dummy',
                                        room: Room(
                                          id: '!style_dummy',
                                          client: client,
                                        ),
                                        content: {'membership': 'join'},
                                        type: EventTypes.RoomMember,
                                        senderId: client.userID!,
                                        originServerTs: DateTime.now(),
                                        stateKey: client.userID,
                                      ),
                                    ),
                                    _BubblePreview(
                                      wallpaper:
                                          accountConfig.wallpaperUrl != null,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Divider(color: theme.dividerColor),
                    ListTile(
                      title: TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          foregroundColor:
                              theme.colorScheme.onSecondaryContainer,
                        ),
                        onPressed: controller.setWallpaper,
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(L10n.of(context).setWallpaper),
                      ),
                      trailing: accountConfig.wallpaperUrl == null
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.delete_outlined),
                              color: theme.colorScheme.error,
                              onPressed: controller.deleteChatWallpaper,
                            ),
                    ),
                    if (accountConfig.wallpaperUrl != null) ...[
                      ListTile(title: Text(L10n.of(context).opacity)),
                      Slider.adaptive(
                        min: 0.1,
                        max: 1.0,
                        divisions: 9,
                        semanticFormatterCallback: (d) => d.toString(),
                        value: controller.wallpaperOpacity,
                        onChanged: controller.updateWallpaperOpacity,
                        onChangeEnd: controller.saveWallpaperOpacity,
                      ),
                      ListTile(title: Text(L10n.of(context).blur)),
                      Slider.adaptive(
                        min: 0.0,
                        max: 10.0,
                        divisions: 10,
                        semanticFormatterCallback: (d) => d.toString(),
                        value: controller.wallpaperBlur,
                        onChanged: controller.updateWallpaperBlur,
                        onChangeEnd: controller.saveWallpaperBlur,
                      ),
                    ],
                  ],
                );
              },
            ),
            ListTile(
              title: Text(L10n.of(context).fontSize),
              trailing: Text('× ${AppSettings.fontSizeFactor.value}'),
            ),
            Slider.adaptive(
              min: 0.5,
              max: 2.5,
              divisions: 20,
              value: AppSettings.fontSizeFactor.value,
              semanticFormatterCallback: (d) => d.toString(),
              onChanged: controller.changeFontSizeFactor,
            ),
          ],
        ),
      ),
    );
  }
}

/// The sample conversation's height on a phone at text scale 1, so the
/// placeholder and the built preview take the same room.
const double _previewMinHeight = 340;

/// Sample conversation drawn with the real [ConversationBubble]s, so the
/// preview follows the chat: an incoming group, then an outgoing reply
/// (quote and caption coloured like the timeline) and a follow-up.
class _BubblePreview extends StatelessWidget {
  final bool wallpaper;
  const _BubblePreview({required this.wallpaper});

  static const _name = 'Lorem';
  static const _quoted = 'Consetetur sadipscing elitr, sed diam nonumy';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColors = ConversationBubbleColors.of(context);
    final pageBackground = context.notion.colors.background;
    final quoteColors = ConversationReplyQuote.colorsFor(
      side: bubbleColors.incoming,
      page: pageBackground,
      muted: bubbleColors.metadata,
    );
    Widget text(String value) => Text(value, style: NotionType.body);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: NotionSpace.sm,
        end: NotionSpace.sm,
        bottom: NotionSpace.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConversationBubble(
            outgoing: false,
            groupPosition: ConversationGroupPosition.first,
            body: text('Lorem ipsum dolor sit amet'),
          ),
          ConversationBubble(
            outgoing: false,
            groupPosition: ConversationGroupPosition.last,
            avatar: const Avatar(name: _name, size: NotionBubble.avatar),
            body: text(_quoted),
          ),
          ConversationBubble(
            outgoing: true,
            groupPosition: ConversationGroupPosition.first,
            quote: ConversationReplyQuote(
              text: _quoted,
              fill: quoteColors.fill,
              textColor: quoteColors.text,
              outgoing: true,
              caption: ConversationReplyCaption(
                label: L10n.of(context).replyCaptionYouReplied(_name),
                color: NotionContrast.readable(
                  pageBackground,
                  theme.colorScheme.onSurfaceVariant,
                ),
                backdrop: wallpaper ? pageBackground : null,
              ),
            ),
            body: text('At vero eos et accusam'),
          ),
          ConversationBubble(
            outgoing: true,
            groupPosition: ConversationGroupPosition.last,
            body: text('Stet clita kasd gubergren'),
          ),
        ],
      ),
    );
  }
}

/// The system accent (Android 12+ dynamic color), read once per process from
/// the platform and refreshed in the background on later opens. The
/// Appearance page then draws its swatches complete on the first frame,
/// without waiting for a platform channel reply.
abstract final class _SystemAccent {
  static ({Color? light, Color? dark})? value;
  static Future<({Color? light, Color? dark})>? _loading;

  static Future<({Color? light, Color? dark})> refresh() => _loading ??= _read()
      .then((result) {
        value = result;
        return result;
      })
      .whenComplete(() => _loading = null);

  static Future<({Color? light, Color? dark})> _read() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        return (
          light: palette.toColorScheme().primary,
          dark: palette.toColorScheme(brightness: Brightness.dark).primary,
        );
      }
    } on PlatformException {
      // Not available on this platform; try the accent color.
    }
    try {
      final accent = await DynamicColorPlugin.getAccentColor();
      if (accent != null) {
        return (
          light: ColorScheme.fromSeed(seedColor: accent).primary,
          dark: ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          ).primary,
        );
      }
    } on PlatformException {
      // No dynamic color on this device.
    }
    return (light: null, dark: null);
  }
}

class _ColorSwatches extends StatefulWidget {
  final SettingsStyleController controller;
  final double size;
  const _ColorSwatches({required this.controller, required this.size});

  @override
  State<_ColorSwatches> createState() => _ColorSwatchesState();
}

class _ColorSwatchesState extends State<_ColorSwatches> {
  @override
  void initState() {
    super.initState();
    final before = _SystemAccent.value;
    // The platform read must not land inside the page transition.
    NotionMotion.afterRouteSettled(context, () async {
      final after = await _SystemAccent.refresh();
      if (mounted && after != before) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _SystemAccent.value;
    final systemColor = theme.brightness == Brightness.light
        ? accent?.light
        : accent?.dark;
    final colors = [
      if (systemColor != null) null,
      AppConfig.chatColor,
      ...Colors.primaries,
    ];
    final current = widget.controller.currentColor;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 64,
      ),
      itemCount: colors.length,
      itemBuilder: (context, i) {
        final color = colors[i];
        final selected = current == color;
        // The whole cell is the touch target (at least 48 dp); the label
        // replaces the old hover tooltip for screen readers.
        return Semantics(
          button: true,
          selected: selected,
          label: color == null
              ? L10n.of(context).systemTheme
              : '#${color.hexValue.toRadixString(16).toUpperCase()}',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => widget.controller.setChatColor(color),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color ?? systemColor,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: widget.size,
                  child: selected
                      ? Icon(
                          Icons.check,
                          size: NotionSize.iconSm,
                          color: theme.colorScheme.onPrimary,
                        )
                      : null,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
