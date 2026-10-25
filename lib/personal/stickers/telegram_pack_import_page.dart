// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_pack_import.dart';
import 'sticker_pack_sheet.dart';

/// Settings › Stickers › Telegram packs.
const telegramPackImportPath = '/rooms/settings/chat/stickers/telegram';

/// The user's Telegram packs (ST-08 import from the network's own list) on
/// a settings page, so it scrolls like every other settings list.
void showTelegramPackImport(BuildContext context) =>
    context.push(telegramPackImportPath);

/// Every sticker and custom emoji set of the user's Telegram account, each
/// with Add (Telegram's "Add stickers"), and Add all for the ones ChatLoom
/// does not have yet. A tap opens the pack's preview sheet.
class TelegramPackImportPage extends StatefulWidget {
  const TelegramPackImportPage({
    super.key,
    required this.client,
    this.provisioning,
    this.library,
  });

  final Client client;
  final StickerPackProvisioning? provisioning;
  final StickerLibrary? library;

  @override
  State<TelegramPackImportPage> createState() => _TelegramPackImportPageState();
}

class _TelegramPackImportPageState extends State<TelegramPackImportPage> {
  late final StickerLibrary _library =
      widget.library ?? StickerLibrary.of(widget.client);
  late final StickerPackProvisioning _provisioning =
      widget.provisioning ?? StickerPackProvisioning.of(widget.client);
  List<RemoteStickerPack>? _packs;
  String? _error;
  final _adding = <String>{};
  final _errors = <String, String>{};

  /// Add all: how many of [_addAllTotal] are done, null when not running.
  int? _addAllDone;
  int _addAllTotal = 0;

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _packs = null;
    });
    try {
      final packs = await _provisioning.listPacks();
      if (mounted) setState(() => _packs = packs);
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Returns whether the pack is installed now.
  Future<bool> _add(RemoteStickerPack pack) async {
    final url = pack.link.url;
    if (_adding.contains(url)) return false;
    if (_library.isInstalled(url)) return true;
    setState(() {
      _adding.add(url);
      _errors.remove(url);
    });
    try {
      await _provisioning.install(
        pack.link,
        title: pack.title,
        library: _library,
      );
      return true;
    } on StickerImportException catch (e) {
      if (mounted) setState(() => _errors[url] = e.message);
      return false;
    } finally {
      if (mounted) setState(() => _adding.remove(url));
    }
  }

  /// One pack after another (each import uploads the whole pack through
  /// the bridge), stickers first; stops when the page closes.
  Future<void> _addAll(List<RemoteStickerPack> missing) async {
    setState(() {
      _addAllDone = 0;
      _addAllTotal = missing.length;
    });
    var failed = 0;
    for (final pack in missing) {
      if (!mounted) return;
      if (!await _add(pack)) failed++;
      if (!mounted) return;
      setState(() => _addAllDone = _addAllDone! + 1);
    }
    final added = missing.length - failed;
    setState(() => _addAllDone = null);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? (added == 1 ? '1 pack added' : '$added packs added')
              : '$added added, $failed couldn’t be added',
        ),
      ),
    );
  }

  Widget _row(RemoteStickerPack pack) {
    final notion = context.notion;
    final url = pack.link.url;
    final installed = _library.isInstalled(url);
    final failure = _errors[url];
    return NotionListRow(
      key: ValueKey(url),
      leading: Icon(
        pack.emoji
            ? Icons.emoji_emotions_outlined
            : Icons.sticky_note_2_outlined,
        color: notion.colors.textSecondary,
      ),
      title: pack.title,
      subtitle: failure ?? (installed ? 'In your stickers' : null),
      onTap: () => showStickerPackSheet(
        context,
        client: widget.client,
        link: pack.link,
        provisioning: _provisioning,
        library: _library,
      ),
      trailing: installed
          ? Icon(
              Icons.check,
              semanticLabel: 'Added',
              color: notion.colors.textSecondary,
            )
          : NotionButton(
              label: failure == null ? 'Add' : 'Retry',
              busy: _adding.contains(url),
              onPressed: _adding.contains(url) ? null : () => _add(pack),
            ),
    );
  }

  Widget _body() {
    final notion = context.notion;
    final error = _error;
    final packs = _packs;
    if (error != null) {
      return NotionCallout(
        icon: Icons.error_outline,
        tone: NotionCalloutTone.warning,
        title: error,
        actionLabel: 'Try again',
        onAction: _load,
      );
    }
    if (packs == null) {
      return NotionSkeleton(
        enabled: true,
        child: Column(
          children: [for (var i = 0; i < 6; i++) const NotionSkeletonRow()],
        ),
      );
    }
    if (packs.isEmpty) {
      return const NotionEmptyState(
        icon: Icons.emoji_emotions_outlined,
        title: 'No sticker packs on Telegram',
        message: 'Packs you add in Telegram show up here.',
      );
    }
    final stickers = [
      for (final p in packs)
        if (!p.emoji) p,
    ];
    final emoji = [
      for (final p in packs)
        if (p.emoji) p,
    ];
    final missing = [
      for (final p in [...stickers, ...emoji])
        if (!_library.isInstalled(p.link.url)) p,
    ];
    final added = packs.length - missing.length;
    final done = _addAllDone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            packs.length == 1
                ? '1 pack on Telegram'
                : '${packs.length} packs on Telegram',
            '$added added',
          ].join(' · '),
          style: notion.typography.footnoteMuted,
        ),
        const SizedBox(height: NotionSpace.sm),
        NotionButton.primary(
          key: const ValueKey('telegram-add-all'),
          label: done != null
              ? 'Adding ${done + 1} of $_addAllTotal…'
              : missing.isEmpty
              ? 'All packs added'
              : missing.length == 1
              ? 'Add 1 pack'
              : 'Add all ${missing.length} packs',
          icon: Icons.download_outlined,
          expand: true,
          busy: done != null,
          onPressed: done != null || missing.isEmpty
              ? null
              : () => _addAll(missing),
        ),
        if (stickers.isNotEmpty) ...[
          const NotionSettingsSection('Stickers'),
          for (final pack in stickers) _row(pack),
        ],
        if (emoji.isNotEmpty) ...[
          const NotionSettingsSection('Custom emoji'),
          for (final pack in emoji) _row(pack),
        ],
        Padding(
          padding: const EdgeInsets.only(top: NotionSpace.lg),
          child: Text(
            'Packs are copied through your Telegram bridge, so they also '
            'work in other Matrix apps. Custom emoji sets are sent as '
            'stickers. Removing a pack in ChatLoom doesn’t remove it from '
            'Telegram.',
            style: notion.typography.footnoteMuted,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => NotionSettingsScaffold(
    title: 'Telegram sticker packs',
    actions: [
      if (_error == null && _packs != null)
        NotionIconButton(
          icon: Icons.refresh,
          label: 'Refresh',
          onPressed: _addAllDone == null ? _load : null,
        ),
    ],
    child: _body(),
  );
}
