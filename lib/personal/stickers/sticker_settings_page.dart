// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_import.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_store.dart';
import 'sticker_tile.dart';

/// Settings › Chats & media › Stickers (Telegram's `StickersActivity`):
/// installed packs in the panel's order (drag to reorder, remove with
/// Undo), packs other apps enabled (hide), import from Telegram or a link,
/// and clearing recents.
class StickerSettingsPage extends StatefulWidget {
  const StickerSettingsPage({super.key, required this.client, this.library});

  final Client client;
  final StickerLibrary? library;

  @override
  State<StickerSettingsPage> createState() => _StickerSettingsPageState();
}

class _StickerSettingsPageState extends State<StickerSettingsPage> {
  late final StickerLibrary _library =
      widget.library ?? StickerLibrary.of(widget.client);

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    super.dispose();
  }

  void _say(String text, {VoidCallback? undo}) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(text),
          action: undo == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: undo),
        ),
      );

  void _remove(StickerPack pack) {
    final index = _library.doc.packs.indexWhere((r) => r.key == pack.key);
    _library.removePack(pack);
    _say(
      pack.ref == null ? '${pack.title} hidden' : '${pack.title} removed',
      undo: () => _library.restorePack(pack, index: index < 0 ? null : index),
    );
  }

  void _reorder(List<StickerPack> installed, int from, int to) {
    final keys = [for (final p in installed) p.key];
    final moved = keys.removeAt(from);
    keys.insert(to.clamp(0, keys.length), moved);
    _library.reorderPacks(keys);
  }

  Future<void> _addFromLink() async {
    final controller = TextEditingController();
    String? error;
    final link = await showNotionCustomDialog<StickerPackLink>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          void submit() {
            final parsed = StickerPackLink.parse(controller.text);
            if (parsed == null) {
              setState(
                () => error =
                    'Paste a t.me/addstickers or wa.me/stickerpack link.',
              );
              return;
            }
            Navigator.of(context).pop(parsed);
          }

          return NotionDialog(
            title: 'Add a sticker pack',
            content: NotionTextField(
              controller: controller,
              autofocus: true,
              hint: 'https://t.me/addstickers/…',
              error: error,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
            ),
            actions: [
              NotionButton.ghost(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
              ),
              NotionButton.primary(label: 'Open', onPressed: submit),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (link == null || !mounted) return;
    await showStickerPackSheet(
      context,
      client: widget.client,
      link: link,
      library: _library,
    );
  }

  void _clearRecent() {
    final previous = _library.list(StickerList.recentStickers);
    if (previous.isEmpty) return;
    _library.clearRecentStickers();
    _say(
      'Recent stickers cleared',
      undo: () {
        for (final item in previous) {
          _library.restore(StickerList.recentStickers, item);
        }
      },
    );
  }

  Widget _packIcon(StickerPack pack) {
    final uri = pack.icon;
    if (uri == null) {
      return Icon(
        Icons.sticky_note_2_outlined,
        color: context.notion.colors.textSecondary,
      );
    }
    return TickerMode(
      enabled: false,
      child: MxcImage(
        uri: uri,
        client: widget.client,
        width: NotionSize.iconLg,
        height: NotionSize.iconLg,
        fit: BoxFit.contain,
        cacheKey: uri.toString(),
        cacheName: stickerCacheName,
        borderRadius: NotionRadius.xsAll,
        animationDuration: Duration.zero,
        placeholder: (_) => Icon(
          Icons.sticky_note_2_outlined,
          color: context.notion.colors.textTertiary,
        ),
        usePlaceholderOnError: true,
      ),
    );
  }

  String _subtitle(StickerPack pack) {
    final count = pack.stickers.length == 1
        ? '1 sticker'
        : '${pack.stickers.length} stickers';
    final source = switch (pack.source) {
      StickerPackSource.enabledElsewhere => 'From another app',
      StickerPackSource.user => 'Your own pack',
      _ => pack.network == null ? null : notionNetworkLabel(pack.network!),
    };
    return [count, ?source].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final packs = _library.packs;
    final installed = [
      for (final pack in packs)
        if (pack.source == StickerPackSource.installed) pack,
    ];
    final others = [
      for (final pack in packs)
        if (pack.source != StickerPackSource.installed) pack,
    ];
    final recentCount = _library.list(StickerList.recentStickers).length;
    return NotionSettingsScaffold(
      title: 'Stickers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Sticker packs'),
          if (installed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
              child: Text(
                'No sticker packs yet. Import your Telegram packs or open a pack link.',
                style: notion.typography.footnoteMuted,
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: installed.length,
              onReorderItem: (from, to) => _reorder(installed, from, to),
              // A flat lifted row (no elevation shadow, DESIGN.md).
              proxyDecorator: (child, _, _) => Material(
                color: notion.colors.selected,
                borderRadius: NotionRadius.rowAll,
                child: child,
              ),
              itemBuilder: (context, i) {
                final pack = installed[i];
                return KeyedSubtree(
                  key: ValueKey(pack.key),
                  child: NotionListRow(
                    leading: _packIcon(pack),
                    title: pack.title,
                    subtitle: _subtitle(pack),
                    onTap: () => showStickerPackSheet(
                      context,
                      client: widget.client,
                      pack: pack,
                      library: _library,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NotionIconButton(
                          icon: Icons.remove_circle_outline,
                          label: 'Remove ${pack.title}',
                          onPressed: () => _remove(pack),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.all(NotionSpace.xs),
                            child: Icon(
                              Icons.drag_handle,
                              semanticLabel: 'Reorder ${pack.title}',
                              color: notion.colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (others.isNotEmpty) ...[
            const NotionSettingsSection('From other apps'),
            for (final pack in others)
              NotionListRow(
                key: ValueKey(pack.key),
                leading: _packIcon(pack),
                title: pack.title,
                subtitle: _subtitle(pack),
                onTap: () => showStickerPackSheet(
                  context,
                  client: widget.client,
                  pack: pack,
                  library: _library,
                ),
                trailing: NotionIconButton(
                  icon: Icons.visibility_off_outlined,
                  label: 'Hide ${pack.title}',
                  onPressed: () => _remove(pack),
                ),
              ),
          ],
          const NotionSettingsSection('Add packs'),
          NotionListRow(
            leading: const Icon(Icons.download_outlined),
            title: 'Import from Telegram',
            subtitle: 'The sticker packs installed in your Telegram account',
            onTap: () => showTelegramPackImport(
              context,
              client: widget.client,
              library: _library,
            ),
          ),
          NotionListRow(
            leading: const Icon(Icons.link),
            title: 'Add from a link',
            subtitle: 't.me/addstickers/… or wa.me/stickerpack/…',
            onTap: _addFromLink,
          ),
          const NotionSettingsSection('Suggestions'),
          NotionListRow(
            key: const ValueKey('sticker-suggest-by-emoji'),
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: 'Suggest stickers by emoji',
            subtitle: 'Typing a single emoji shows matching stickers',
            trailing: Switch.adaptive(
              value: AppSettings.stickerSuggestions.value,
              onChanged: (value) async {
                await AppSettings.stickerSuggestions.setItem(value);
                if (mounted) setState(() {});
              },
            ),
          ),
          const NotionSettingsSection('Recent'),
          NotionListRow(
            leading: const Icon(Icons.history),
            title: 'Clear recent stickers',
            subtitle: recentCount == 0
                ? 'Nothing to clear'
                : recentCount == 1
                ? '1 sticker'
                : '$recentCount stickers',
            onTap: recentCount == 0 ? null : _clearRecent,
          ),
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.lg),
            child: Text(
              'Packs, recent and favourite stickers and saved GIFs sync between '
              'your devices through your Matrix account settings, which your '
              'server can read. Stickers and GIFs from encrypted chats that '
              'don’t belong to a public pack stay on this device. Removing a '
              'pack here doesn’t remove it from Telegram.',
              style: notion.typography.footnoteMuted,
            ),
          ),
        ],
      ),
    );
  }
}
