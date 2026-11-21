// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/chat_appearance_preview.dart';
import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_chat_palettes.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// A dismissed dialog returns null. A saved result with an empty theme
/// clears the override.
Future<({ChatTheme? theme})?> showChatAppearanceDialog(
  BuildContext context, {
  required ApplicationAccountConfig accountConfig,
  required ChatTheme? initial,
  ChatTheme? inherited,
}) => showNotionCustomDialog<({ChatTheme? theme})>(
  context: context,
  builder: (_) => _ChatAppearanceDialog(
    accountConfig: accountConfig,
    initial: initial,
    inherited: inherited,
  ),
);

class _ChatAppearanceDialog extends StatefulWidget {
  final ApplicationAccountConfig accountConfig;
  final ChatTheme? initial;
  final ChatTheme? inherited;

  const _ChatAppearanceDialog({
    required this.accountConfig,
    required this.initial,
    required this.inherited,
  });

  @override
  State<_ChatAppearanceDialog> createState() => _ChatAppearanceDialogState();
}

class _ChatAppearanceDialogState extends State<_ChatAppearanceDialog> {
  late int? _incoming = widget.initial?.incomingColor;
  late int? _outgoing = widget.initial?.outgoingColor;
  late int? _solidBackground = widget.initial?.backgroundColor;
  late String? _presetName = widget.initial?.wallpaperAsset;

  bool get _isDefault =>
      _incoming == null &&
      _outgoing == null &&
      _solidBackground == null &&
      _presetName == null;

  ChatTheme? get _theme => _isDefault
      ? null
      : ChatTheme(
          backgroundColor: _solidBackground,
          incomingColor: _incoming,
          outgoingColor: _outgoing,
          wallpaperAsset: _presetName,
        );

  bool get _hasChanges {
    final initial = widget.initial;
    if (_isDefault) return initial != null;
    return (_incoming, _outgoing, _solidBackground, _presetName) !=
        (
          initial?.incomingColor,
          initial?.outgoingColor,
          initial?.backgroundColor,
          initial?.wallpaperAsset,
        );
  }

  NotionWallpaperPreset? get _preset => NotionWallpaperPreset.values
      .where((value) => value.name == _presetName)
      .firstOrNull;

  bool _matches(NotionChatPalette palette) =>
      _preset == palette.background &&
      _outgoing == palette.outgoing.argb &&
      _incoming == null &&
      _solidBackground == null;

  void _selectPalette(NotionChatPalette palette) => setState(() {
    _presetName = palette.background.name;
    _solidBackground = null;
    _outgoing = palette.outgoing.argb;
    _incoming = null;
  });

  void _reset() => setState(() {
    _presetName = null;
    _solidBackground = null;
    _outgoing = null;
    _incoming = null;
  });

  String _colorLabel(int? value) => value == null
      ? 'App default'
      : NotionMessageColor.fromArgb(value)?.label ?? 'Custom colour';

  Future<void> _pickBackground() async {
    final strength = NotionDisplayPreferences.of(context).wallpaperStrength;
    final selected = _preset;
    final useDefault = selected == null && _solidBackground == null;
    final picked = await showNotionSheet<NotionChoice<NotionWallpaperPreset?>>(
      context: context,
      title: 'Background',
      builder: (context) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionChoiceRow(
              title: 'App default',
              selected: useDefault,
              onTap: () => Navigator.pop(
                context,
                const NotionChoice<NotionWallpaperPreset?>(null, 'App default'),
              ),
            ),
            NotionWallpaperGallery(
              selected: selected,
              strength: strength,
              onSelected: (preset) => Navigator.pop(
                context,
                NotionChoice<NotionWallpaperPreset?>(preset, preset.label),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _presetName = picked.value?.name;
      _solidBackground = null;
    });
  }

  Future<void> _pickMessageColour({required bool outgoing}) async {
    final selected = outgoing ? _outgoing : _incoming;
    const options = NotionMessageColor.values;
    final picked = await showNotionSheet<NotionChoice<int?>>(
      context: context,
      title: outgoing ? 'Outgoing messages' : 'Incoming messages',
      builder: (context) {
        Widget choice(String label, int? value) => NotionGlassPill(
          label: label,
          selected: value == selected,
          icon: value == selected ? Icons.check : null,
          trailing: value == null ? null : _ColourDot(fill: Color(value)),
          onPressed: () =>
              Navigator.pop(context, NotionChoice<int?>(value, label)),
        );

        return SingleChildScrollView(
          child: Wrap(
            spacing: NotionSpace.xs,
            runSpacing: NotionSpace.xs,
            children: [
              choice('App default', null),
              if (selected != null &&
                  NotionMessageColor.fromArgb(selected) == null)
                choice('Custom colour', selected),
              for (final option in options) choice(option.label, option.argb),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (outgoing) {
        _outgoing = picked.value;
      } else {
        _incoming = picked.value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final effective = _theme ?? widget.inherited;
    final selection = resolveChatBackground(
      context,
      widget.accountConfig,
      theme: effective,
    );
    final incoming = effective?.incomingColor;
    final outgoing = effective?.outgoingColor;
    return NotionDialog(
      title: 'Chat appearance',
      message: 'Only visible to you.',
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChatAppearancePreview(
                background: ChatBackground(selection: selection),
                backgroundColor: selection.solid,
                incomingColor: incoming == null ? null : Color(incoming),
                outgoingColor: outgoing == null ? null : Color(outgoing),
              ),
              const NotionSectionHeader(title: 'Themes'),
              Wrap(
                spacing: NotionSpace.xs,
                runSpacing: NotionSpace.xs,
                children: [
                  for (final palette in NotionChatPalette.values)
                    NotionGlassPill(
                      label: palette.label,
                      selected: _matches(palette),
                      icon: _matches(palette) ? Icons.check : null,
                      trailing: _ColourDot(fill: palette.outgoing.fill),
                      onPressed: () => _selectPalette(palette),
                    ),
                ],
              ),
              const NotionSectionHeader(title: 'Customize'),
              NotionListRow(
                leading: const Icon(Icons.wallpaper_outlined),
                title: 'Background',
                subtitle:
                    _preset?.label ??
                    (_solidBackground == null
                        ? 'App default'
                        : 'Custom colour'),
                onTap: _pickBackground,
              ),
              NotionListRow(
                leading: const Icon(Icons.send_outlined),
                title: 'Outgoing messages',
                subtitle: _colorLabel(_outgoing),
                onTap: () => _pickMessageColour(outgoing: true),
              ),
              NotionListRow(
                leading: const Icon(Icons.chat_bubble_outline),
                title: 'Incoming messages',
                subtitle: _colorLabel(_incoming),
                onTap: () => _pickMessageColour(outgoing: false),
              ),
              if (!_isDefault)
                NotionListRow(
                  leading: const Icon(Icons.restore),
                  title: 'Use default appearance',
                  onTap: _reset,
                ),
            ],
          ),
        ),
      ),
      actions: [
        NotionButton.ghost(
          label: MaterialLocalizations.of(context).cancelButtonLabel,
          onPressed: () => Navigator.pop(context),
        ),
        NotionButton.primary(
          label: 'Save',
          onPressed: _hasChanges
              ? () => Navigator.pop(context, (theme: _theme))
              : null,
        ),
      ],
    );
  }
}

class _ColourDot extends StatelessWidget {
  final Color fill;

  const _ColourDot({required this.fill});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: NotionSize.iconSm,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: context.notion.colors.border),
      ),
    ),
  );
}
